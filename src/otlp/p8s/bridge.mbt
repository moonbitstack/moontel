// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Turn a snapshot of Prometheus families into OTLP metrics.
///
/// A program that already keeps metrics does not need a second meter: it hands the
/// snapshot it has to this function, and the result goes to `otlp.MetricsExporter`
/// unchanged. Nothing is accumulated here — a counter that has been counting since
/// the process started keeps its total, which is what the mapping below says a
/// cumulative sum is.
///
/// The conversion follows the OpenTelemetry compatibility specification's table
/// for Prometheus and OpenMetrics, one row at a time:
///
/// - a counter is a monotonic, cumulative sum;
/// - a gauge is a gauge, and so is a family with no type metadata;
/// - a histogram is a cumulative histogram with explicit bounds;
/// - a summary is a summary;
/// - info and state sets are non-monotonic sums, which is what lets a reader add
///   them up across series;
/// - a gauge histogram has no OTLP instrument and is dropped, and said to be.
///
/// A name loses the unit the exposition appended: `http_requests` registered with
/// unit `seconds` is written out as `http_requests_seconds`, and the OTLP name is
/// `http_requests` with `s` in the unit field. A name that does not end in its own
/// unit is left as it is, and so is `_total`.
///
/// `at` is when the snapshot was taken, in nanoseconds; a point that carries no
/// timestamp of its own is dated with it.
pub fn bridge(
  families : Array[@metric.MetricFamily],
  at~ : Int64,
  start? : Int64,
) -> Array[@otlp.Metric] {
  bridge_with_report(families, at~, start?).metrics
}

///|
/// What a bridge did: the metrics it produced, and the families it dropped.
///
/// A caller that only wants the metrics calls `bridge`; one that keeps a count of
/// what did not survive the conversion — a gauge histogram, and nothing else today —
/// calls this and reads `dropped`.
pub fn bridge_with_report(
  families : Array[@metric.MetricFamily],
  at~ : Int64,
  start? : Int64,
) -> Report {
  let metrics : Array[@otlp.Metric] = []
  let dropped : Array[Dropped] = []
  for family in families {
    match convert(family, at, start) {
      Some(metric) => metrics.push(metric)
      None => dropped.push({ name: family.name, kind: family.kind, })
    }
  }
  { metrics, dropped, }
}

///|
/// The metrics a bridge produced, and the families it left out.
pub(all) struct Report {
  metrics : Array[@otlp.Metric]
  /// The families whose kind has no OTLP instrument, in the order they arrived.
  dropped : Array[Dropped]
}

///|
/// A family the bridge left out, and what it was.
pub(all) struct Dropped {
  /// The family name as it arrived, unit suffix and all.
  name : String
  /// The Prometheus kind, which is what decided it.
  kind : @metric.Kind
}

///|
fn convert(
  family : @metric.MetricFamily,
  at : Int64,
  start : Int64?,
) -> @otlp.Metric? {
  let kind = match family.kind {
    @metric.Counter => @otlp.Sum(temporality=Cumulative, monotonic=true)
    @metric.Gauge => @otlp.Gauge
    @metric.Histogram => @otlp.Histogram(temporality=Cumulative)
    @metric.Summary => @otlp.Summary
    @metric.Info => @otlp.Sum(temporality=Cumulative, monotonic=false)
    @metric.StateSet => @otlp.Sum(temporality=Cumulative, monotonic=false)
    @metric.Unknown => @otlp.Gauge
    // A gauge histogram counts up and down over buckets, which no OTLP instrument
    // describes; the compatibility table says to drop it rather than pretend.
    @metric.GaugeHistogram => return None
  }
  let points : Array[@otlp.DataPoint] = []
  for point in family.metrics {
    let time = match point.timestamp {
      Some(seconds) => nanos(seconds)
      None => at
    }
    let begin = match point.created {
      Some(seconds) => Some(nanos(seconds))
      None => start
    }
    let base : @otlp.DataPoint = {
      attributes: attributes_of(point.labels),
      start: begin,
      time,
      point: @otlp.AsDouble(0.0),
      exemplars: exemplars_of(point.exemplars, time),
      flags: 0,
    }
    match point.value {
      @metric.Number(value) =>
        points.push({ ..base, point: @otlp.AsDouble(value), })
      @metric.Buckets(buckets~, sum~, count~) => {
        let (bounds, counts) = bucket_counts(buckets, count)
        points.push({
          ..base,
          point: @otlp.Buckets(
            bounds~,
            counts~,
            sum~,
            count~,
            min=None,
            max=None,
          ),
        })
      }
      @metric.Quantiles(quantiles~, sum~, count~) =>
        points.push({
          ..base,
          point: @otlp.Quantiles(quantiles~, sum~, count~),
        })
      // One state set is one data point per state in OTLP, each carrying the state
      // it describes: a reader that sums the series gets the number of set states.
      @metric.State(states~) =>
        for state in states {
          let attributes = base.attributes.copy()
          attributes.push(("state", @trace.Str(state.0)))
          points.push({
            ..base,
            attributes,
            point: @otlp.AsDouble(if state.1 { 1.0 } else { 0.0 }),
          })
        }
    }
  }
  let unit = family.unit
  let metric : @otlp.Metric = {
    name: otlp_name(family.name, unit),
    description: family.help,
    unit: match unit {
      Some(unit) => ucum(unit)
      None => ""
    },
    kind,
    points,
  }
  Some(metric)
}

///|
/// The bounds and the counts OTLP wants: one count per bucket rather than a running
/// total, and one more count than there are bounds.
///
/// A Prometheus snapshot counts cumulatively over finite upper bounds and leaves the
/// `+Inf` bucket out, so the differences are taken here and the remainder over the
/// last bound becomes the final count.
fn bucket_counts(
  buckets : Array[(Double, Int64)],
  total : Int64,
) -> (Array[Double], Array[Int64]) {
  let bounds : Array[Double] = []
  let counts : Array[Int64] = []
  let mut previous = 0L
  for bucket in buckets {
    bounds.push(bucket.0)
    counts.push(bucket.1 - previous)
    previous = bucket.1
  }
  counts.push(total - previous)
  (bounds, counts)
}

///|
fn attributes_of(
  labels : Array[(String, String)],
) -> Array[(String, @trace.Value)] {
  labels.map(label => (label.0, @trace.Str(label.1)))
}

///|
fn exemplars_of(
  exemplars : Array[@metric.Exemplar],
  fallback : Int64,
) -> Array[@otlp.Exemplar] {
  let out : Array[@otlp.Exemplar] = []
  for exemplar in exemplars {
    out.push({
      time: match exemplar.timestamp {
        Some(seconds) => nanos(seconds)
        None => fallback
      },
      value: exemplar.value,
      attributes: attributes_of(exemplar.labels),
      trace_id: None,
      span_id: None,
    })
  }
  out
}

///|
fn nanos(seconds : Double) -> Int64 {
  (seconds * 1000000000.0).to_int64()
}

///|
/// The name OTLP carries: the family name without the unit suffix the exposition
/// appended.
///
/// The compatibility specification says a Prometheus name is not to be altered, and
/// for a name read off an exposition that is the right rule. This bridge is usually
/// handed the snapshot of a registry that appended the unit itself — `apply_unit` in
/// `moonp8s` does exactly that — so the suffix is the exposition's doing rather than
/// part of the name, and taking it off recovers the name the author wrote. The
/// collector's Prometheus receiver has the same switch, for the same reason.
///
/// Only a suffix that is really there is removed: a family registered as `errors`
/// with unit `seconds` keeps its name, because nothing appended anything to it.
fn otlp_name(name : String, unit : String?) -> String {
  match unit {
    Some(unit) => {
      let suffix = "_" + unit
      if name.length() > suffix.length() && name.has_suffix(suffix[:]) {
        name[:name.length() - suffix.length()].to_owned()
      } else {
        name
      }
    }
    None => name
  }
}

///|
/// The UCUM code for a Prometheus unit, which is the form OTLP carries: the
/// compatibility specification lists the pairs, and a unit it does not list travels
/// as it was written.
fn ucum(unit : String) -> String {
  match unit {
    "days" => "d"
    "hours" => "h"
    "minutes" => "min"
    "seconds" => "s"
    "milliseconds" => "ms"
    "microseconds" => "us"
    "nanoseconds" => "ns"
    "bytes" => "By"
    "kibibytes" => "KiBy"
    "mebibytes" => "MiBy"
    "gibibytes" => "GiBy"
    "tebibytes" => "TiBy"
    "kilobytes" => "kBy"
    "megabytes" => "MBy"
    "gigabytes" => "GBy"
    "terabytes" => "TBy"
    "meters" => "m"
    "volts" => "V"
    "amperes" => "A"
    "joules" => "J"
    "watts" => "W"
    "grams" => "g"
    "celsius" => "Cel"
    "hertz" => "Hz"
    "percent" => "%"
    other => other
  }
}

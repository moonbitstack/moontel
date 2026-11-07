// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Whether a data point counts from the start of the process or since the last
/// export. OTLP names the two `AGGREGATION_TEMPORALITY_DELTA` (1) and
/// `AGGREGATION_TEMPORALITY_CUMULATIVE` (2), and a reader has to know which one it
/// is looking at before it can add two points together.
#derive(Eq, Debug)
pub(all) enum Temporality {
  Delta
  Cumulative
}

///|
pub extend Temporality with Eq::{equal, not_equal}

///|
pub extend Temporality with Debug::{to_repr}

///|
/// One measurement of one point.
///
/// The four shapes are the four ways OTLP carries a value: a double for a gauge or
/// a sum, an integer for a counter a producer keeps whole, a set of buckets for a
/// histogram, and quantiles for a summary. Which one a metric uses is fixed by its
/// kind, not by the point.
#derive(Eq, Debug)
pub(all) enum Point {
  AsDouble(Double)
  AsInt(Int64)
  /// A histogram: the finite upper bounds of its buckets, one more count than
  /// there are bounds — the last count is everything above the last bound, which is
  /// how OTLP states the `+Inf` bucket.
  Buckets(
    bounds~ : Array[Double],
    counts~ : Array[Int64],
    sum~ : Double,
    count~ : Int64,
    min~ : Double?,
    max~ : Double?
  )
  Quantiles(quantiles~ : Array[(Double, Double)], sum~ : Double, count~ : Int64)
}

///|
pub extend Point with Eq::{equal, not_equal}

///|
pub extend Point with Debug::{to_repr}

///|
/// A sample kept beside an aggregate: one measurement, when it was taken, and the
/// trace it was taken in, so a reader can jump from a slow bucket to the request
/// that filled it.
#derive(Eq, Debug)
pub(all) struct Exemplar {
  time : Int64
  value : Double
  attributes : Array[(String, @trace.Value)]
  trace_id : Bytes?
  span_id : Bytes?
}

///|
pub extend Exemplar with Eq::{equal, not_equal}

///|
pub extend Exemplar with Debug::{to_repr}

///|
/// A metric named `value`, taken at `time`, carrying the attributes that say which
/// series it belongs to.
#derive(Eq, Debug)
pub(all) struct DataPoint {
  attributes : Array[(String, @trace.Value)]
  /// When the accumulation began, when the producer knows. A delta point has no
  /// start of its own, and OTLP leaves the field out rather than inventing one.
  start : Int64?
  time : Int64
  point : Point
  exemplars : Array[Exemplar]
  flags : Int32
}

///|
pub extend DataPoint with Eq::{equal, not_equal}

///|
pub extend DataPoint with Debug::{to_repr}

///|
/// Which OTLP instrument a metric is exported as.
///
/// A counter and a monotonic sum are the same thing to a reader — a number that
/// only goes up — so one variant carries both the temporality and the monotonic
/// bit rather than four variants spelling out the combinations.
#derive(Eq, Debug)
pub(all) enum MetricKind {
  Gauge
  Sum(temporality~ : Temporality, monotonic~ : Bool)
  Histogram(temporality~ : Temporality)
  Summary
}

///|
pub extend MetricKind with Eq::{equal, not_equal}

///|
pub extend MetricKind with Debug::{to_repr}

///|
/// One metric and the points it was measured at.
#derive(Eq, Debug)
pub(all) struct Metric {
  name : String
  description : String
  unit : String
  kind : MetricKind
  points : Array[DataPoint]
}

///|
pub extend Metric with Eq::{equal, not_equal}

///|
pub extend Metric with Debug::{to_repr}

///|
/// Encode metrics as an OTLP/JSON `ExportMetricsServiceRequest`, the body
/// `POST /v1/metrics` takes.
pub fn encode_metrics(
  metrics : Array[Metric],
  resource~ : Resource = unknown_service,
  scope~ : Scope = moonbit_scope,
) -> String {
  let w = JsonWriter::new()
  w.open_object()
  w.name("resourceMetrics")
  w.open_array()
  w.open_object()
  w.name("resource")
  write_resource(w, resource)
  w.name("scopeMetrics")
  w.open_array()
  w.open_object()
  w.name("scope")
  write_scope(w, scope)
  w.name("metrics")
  w.open_array()
  for metric in metrics {
    write_metric(w, metric)
  }
  w.close_array()
  w.close_object()
  w.close_array()
  w.close_object()
  w.close_array()
  w.close_object()
  w.text()
}

///|
fn write_metric(w : JsonWriter, metric : Metric) -> Unit {
  w.open_object()
  w.name("name")
  w.string(metric.name)
  if metric.description != "" {
    w.name("description")
    w.string(metric.description)
  }
  if metric.unit != "" {
    w.name("unit")
    w.string(metric.unit)
  }
  match metric.kind {
    Gauge => {
      w.name("gauge")
      write_points(w, metric.points)
    }
    Sum(temporality~, monotonic~) => {
      w.name("sum")
      w.open_object()
      w.name("dataPoints")
      write_data_points(w, metric.points)
      w.name("aggregationTemporality")
      w.raw(temporality_code(temporality).to_string())
      if monotonic {
        w.name("isMonotonic")
        w.boolean(true)
      }
      w.close_object()
    }
    Histogram(temporality~) => {
      w.name("histogram")
      w.open_object()
      w.name("dataPoints")
      write_data_points(w, metric.points)
      w.name("aggregationTemporality")
      w.raw(temporality_code(temporality).to_string())
      w.close_object()
    }
    Summary => {
      w.name("summary")
      write_points(w, metric.points)
    }
  }
  w.close_object()
}

///|
/// A gauge or a summary body, which is a data-point list and nothing else.
fn write_points(w : JsonWriter, points : Array[DataPoint]) -> Unit {
  w.open_object()
  w.name("dataPoints")
  write_data_points(w, points)
  w.close_object()
}

///|
fn write_data_points(w : JsonWriter, points : Array[DataPoint]) -> Unit {
  w.open_array()
  for point in points {
    write_data_point(w, point)
  }
  w.close_array()
}

///|
fn write_data_point(w : JsonWriter, data : DataPoint) -> Unit {
  w.open_object()
  if !data.attributes.is_empty() {
    w.name("attributes")
    write_attributes(w, data.attributes)
  }
  match data.start {
    Some(start) => {
      w.name("startTimeUnixNano")
      w.int64(start)
    }
    None => ()
  }
  w.name("timeUnixNano")
  w.int64(data.time)
  match data.point {
    AsDouble(value) => {
      w.name("asDouble")
      w.double(value)
    }
    AsInt(value) => {
      w.name("asInt")
      w.int64(value)
    }
    Buckets(bounds~, counts~, sum~, count~, min~, max~) => {
      w.name("count")
      w.int64(count)
      w.name("sum")
      w.double(sum)
      w.name("bucketCounts")
      w.open_array()
      for bucket in counts {
        w.int64(bucket)
      }
      w.close_array()
      w.name("explicitBounds")
      w.open_array()
      for bound in bounds {
        w.double(bound)
      }
      w.close_array()
      match min {
        Some(value) => {
          w.name("min")
          w.double(value)
        }
        None => ()
      }
      match max {
        Some(value) => {
          w.name("max")
          w.double(value)
        }
        None => ()
      }
    }
    Quantiles(quantiles~, sum~, count~) => {
      w.name("count")
      w.int64(count)
      w.name("sum")
      w.double(sum)
      w.name("quantileValues")
      w.open_array()
      for quantile in quantiles {
        w.open_object()
        w.name("quantile")
        w.double(quantile.0)
        w.name("value")
        w.double(quantile.1)
        w.close_object()
      }
      w.close_array()
    }
  }
  if !data.exemplars.is_empty() {
    w.name("exemplars")
    w.open_array()
    for exemplar in data.exemplars {
      write_exemplar(w, exemplar)
    }
    w.close_array()
  }
  if data.flags != 0 {
    w.name("flags")
    w.raw(data.flags.to_string())
  }
  w.close_object()
}

///|
fn write_exemplar(w : JsonWriter, exemplar : Exemplar) -> Unit {
  w.open_object()
  if !exemplar.attributes.is_empty() {
    w.name("filteredAttributes")
    write_attributes(w, exemplar.attributes)
  }
  w.name("timeUnixNano")
  w.int64(exemplar.time)
  w.name("asDouble")
  w.double(exemplar.value)
  match (exemplar.trace_id, exemplar.span_id) {
    (Some(trace_id), Some(span_id)) => {
      w.name("traceId")
      w.string(@base16.encode(trace_id[:]))
      w.name("spanId")
      w.string(@base16.encode(span_id[:]))
    }
    _ => ()
  }
  w.close_object()
}

///|
pub fn temporality_code(temporality : Temporality) -> Int32 {
  match temporality {
    Delta => 1
    Cumulative => 2
  }
}

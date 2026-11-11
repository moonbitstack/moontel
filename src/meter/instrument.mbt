// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One series of one instrument: its attribute set, when it began, and the
/// accumulated point that will be exported.
///
/// The point is the OTLP shape itself. Accumulating it in place means collection
/// has nothing to translate, and the JSON and protobuf encoders see the same
/// numbers a hand-built metric would carry.
pub struct Series {
  attributes : Attributes
  key : String
  start : Int64
  point : @otlp.Point
  exemplars : Array[@otlp.Exemplar]
}

///|
/// What every instrument of one name shares.
pub struct Instrument {
  name : String
  description : String
  unit : String
  kind : InstrumentKind
  bounds : Array[Double]
  limits : MeterLimits
  temporality : @otlp.Temporality
  now : () -> Int64
  start : Int64
  series : Ref[Array[Series]]
  dropped : Ref[Int32]
}

///|
/// A monotonic sum: `add` may only go up.
pub struct Counter {
  provider : MeterProvider
  index : Int32
}

///|
/// A sum that may go up or down.
pub struct UpDownCounter {
  provider : MeterProvider
  index : Int32
}

///|
/// A distribution over explicit buckets.
pub struct Histogram {
  provider : MeterProvider
  index : Int32
}

///|
/// The last value set, rather than a sum of values.
pub struct Gauge {
  provider : MeterProvider
  index : Int32
}

///|
/// The state behind a handle. The handle carries no numbers of its own: it is a
/// place in the provider's registration list, which is what keeps the state type
/// out of the public surface.
fn Counter::handle(self : Counter) -> Instrument {
  self.provider.instruments.val[self.index]
}

///|
fn UpDownCounter::handle(self : UpDownCounter) -> Instrument {
  self.provider.instruments.val[self.index]
}

///|
fn Histogram::handle(self : Histogram) -> Instrument {
  self.provider.instruments.val[self.index]
}

///|
fn Gauge::handle(self : Gauge) -> Instrument {
  self.provider.instruments.val[self.index]
}

///|
/// Add a non-negative amount.
///
/// A negative or non-finite amount is ignored: the specification says a counter's
/// measurements are non-negative, and a value that cannot be written to the wire
/// is not a value to accumulate. No error is raised on a hot measurement path.
pub fn Counter::add(
  self : Counter,
  value : Double,
  attributes~ : Attributes = empty_attributes,
  at? : Int64,
  context? : @trace.TraceContext,
) -> Unit {
  if value < 0.0 || !finite(value) {
    return
  }
  self.handle().accumulate(value, attributes, at, context, overwrite=false)
}

///|
/// Add one.
pub fn Counter::inc(
  self : Counter,
  attributes~ : Attributes = empty_attributes,
  at? : Int64,
  context? : @trace.TraceContext,
) -> Unit {
  self.add(1.0, attributes~, at?, context?)
}

///|
/// Add a positive or negative amount. Only non-finite values are ignored.
pub fn UpDownCounter::add(
  self : UpDownCounter,
  value : Double,
  attributes~ : Attributes = empty_attributes,
  at? : Int64,
  context? : @trace.TraceContext,
) -> Unit {
  if !finite(value) {
    return
  }
  self.handle().accumulate(value, attributes, at, context, overwrite=false)
}

///|
/// Replace the value of this series. A gauge keeps the most recent measurement;
/// two writes to the same attributes do not add up.
pub fn Gauge::set(
  self : Gauge,
  value : Double,
  attributes~ : Attributes = empty_attributes,
  at? : Int64,
  context? : @trace.TraceContext,
) -> Unit {
  if !finite(value) {
    return
  }
  self.handle().accumulate(value, attributes, at, context, overwrite=true)
}

///|
/// Record one measurement into the bucket whose upper bound contains it.
///
/// The point also keeps `sum`, `count`, `min` and `max`, which the OTLP histogram
/// data point carries so a backend can compute a mean or show the range without
/// guessing from the buckets.
pub fn Histogram::record(
  self : Histogram,
  value : Double,
  attributes~ : Attributes = empty_attributes,
  at? : Int64,
  context? : @trace.TraceContext,
) -> Unit {
  if !finite(value) {
    return
  }
  let instrument = self.handle()
  let at = at.unwrap_or((instrument.now)())
  let attributes = bounded_attributes(attributes, instrument.limits)
  match instrument.series_index(attributes, at) {
    None => instrument.dropped.val = instrument.dropped.val + 1
    Some(index) => {
      let series = instrument.series.val[index]
      let point = match series.point {
        @otlp.Buckets(bounds~, counts~, sum~, count~, min~, max~) => {
          let slot = bucket_index(bounds, value)
          let next_counts = counts.copy()
          next_counts[slot] = next_counts[slot] + 1L
          let next_min = match min {
            Some(current) => Some(if value < current { value } else { current })
            None => Some(value)
          }
          let next_max = match max {
            Some(current) => Some(if value > current { value } else { current })
            None => Some(value)
          }
          @otlp.Buckets(
            bounds~,
            counts=next_counts,
            sum=sum + value,
            count=count + 1L,
            min=next_min,
            max=next_max,
          )
        }
        // A series is created with the point its instrument kind needs, so this
        // arm is unreachable; keeping it makes the match total.
        other => other
      }
      instrument.series.val[index] = {
        ..series,
        point,
        exemplars: exemplars_of(series, value, at, context, instrument.limits),
      }
    }
  }
}

///|
/// How many measurements this instrument refused because its cardinality limit
/// was reached.
fn Instrument::dropped(self : Instrument) -> Int32 {
  self.dropped.val
}

///|
/// Add to a scalar series, or replace it when the instrument is a gauge.
fn Instrument::accumulate(
  self : Instrument,
  value : Double,
  attributes : Attributes,
  at : Int64?,
  context : @trace.TraceContext?,
  overwrite~ : Bool,
) -> Unit {
  let at = at.unwrap_or((self.now)())
  let attributes = bounded_attributes(attributes, self.limits)
  match self.series_index(attributes, at) {
    None => self.dropped.val = self.dropped.val + 1
    Some(index) => {
      let series = self.series.val[index]
      let point = match series.point {
        @otlp.AsDouble(previous) =>
          @otlp.AsDouble(if overwrite { value } else { previous + value })
        other => other
      }
      self.series.val[index] = {
        ..series,
        point,
        exemplars: exemplars_of(series, value, at, context, self.limits),
      }
    }
  }
}

///|
/// The index of the series these attributes name, creating it when there is
/// room. `None` means the cardinality limit was reached and the measurement has
/// to be dropped rather than put in a series of its own.
fn Instrument::series_index(
  self : Instrument,
  attributes : Attributes,
  at : Int64,
) -> Int32? {
  let key = attributes.identity()
  for i in 0..<self.series.val.length() {
    if self.series.val[i].key == key {
      return Some(i)
    }
  }
  if self.series.val.length() >= self.limits.series {
    return None
  }
  let start = if self.temporality == @otlp.Delta { at } else { self.start }
  self.series.val.push({
    attributes,
    key,
    start,
    point: initial_point(self.kind, self.bounds),
    exemplars: [],
  })
  Some(self.series.val.length() - 1)
}

///|
fn initial_point(kind : InstrumentKind, bounds : Array[Double]) -> @otlp.Point {
  match kind {
    Histogram =>
      @otlp.Buckets(
        bounds=bounds.copy(),
        counts=empty_counts(bounds),
        sum=0.0,
        count=0L,
        min=None,
        max=None,
      )
    _ => @otlp.AsDouble(0.0)
  }
}

///|
/// Keep the most recent sampled trace beside the series, up to the limit.
///
/// An exemplar is what lets a reader jump from a slow bucket to the request that
/// filled it. Only a sampled, valid context is one a backend can find, so a
/// dropped span or a zero id contributes nothing.
fn exemplars_of(
  series : Series,
  value : Double,
  at : Int64,
  context : @trace.TraceContext?,
  limits : MeterLimits,
) -> Array[@otlp.Exemplar] {
  let previous = series.exemplars.copy()
  if limits.exemplars <= 0 {
    return previous
  }
  match context {
    Some(context) if context.sampled() && context.is_valid() => {
      previous.push({
        time: at,
        value,
        attributes: [],
        trace_id: Some(context.trace_id),
        span_id: Some(context.span_id),
      })
      let keep = limits.exemplars
      let begin = if previous.length() > keep {
        previous.length() - keep
      } else {
        0
      }
      let recent : Array[@otlp.Exemplar] = []
      for i in begin..<previous.length() {
        recent.push(previous[i])
      }
      recent
    }
    _ => previous
  }
}

///|
/// The attributes a point may keep, cut to the configured limits before they
/// become a series key. A caller that builds attributes from user data must not
/// be able to make one instrument unbounded.
fn bounded_attributes(
  attributes : Attributes,
  limits : MeterLimits,
) -> Attributes {
  let normalized = normalize(attributes.entries)
  let kept : Array[(String, @trace.Value)] = []
  for entry in normalized.entries {
    if kept.length() >= limits.attributes {
      break
    }
    kept.push((entry.0, truncate(entry.1, limits.attribute_value_length)))
  }
  { entries: kept, }
}

///|
fn truncate(value : @trace.Value, limit : Int32?) -> @trace.Value {
  match (value, limit) {
    (@trace.Str(text), Some(n)) if text.length() > n =>
      @trace.Str(text.exact_view(start=0, end=n).to_owned())
    (@trace.Strs(texts), Some(n)) =>
      @trace.Strs(
        texts.map(text => {
          if text.length() > n {
            text.exact_view(start=0, end=n).to_owned()
          } else {
            text
          }
        }),
      )
    _ => value
  }
}

///|
/// One OTLP metric: the family's name, kind and every series collected at `at`.
fn Instrument::to_metric(self : Instrument, at : Int64) -> @otlp.Metric {
  let points : Array[@otlp.DataPoint] = []
  for series in self.series.val {
    let start = match self.kind {
      Gauge => None
      _ =>
        if self.temporality == @otlp.Delta {
          Some(series.start)
        } else {
          Some(self.start)
        }
    }
    points.push({
      attributes: series.attributes.to_array(),
      start,
      time: at,
      point: series.point,
      exemplars: series.exemplars.copy(),
      flags: 0,
    })
  }
  {
    name: self.name,
    description: self.description,
    unit: self.unit,
    kind: metric_kind(self.kind, self.temporality),
    points,
  }
}

///|
fn metric_kind(
  kind : InstrumentKind,
  temporality : @otlp.Temporality,
) -> @otlp.MetricKind {
  match kind {
    Counter => @otlp.Sum(temporality~, monotonic=true)
    UpDownCounter => @otlp.Sum(temporality~, monotonic=false)
    Histogram => @otlp.Histogram(temporality~)
    Gauge => @otlp.Gauge
  }
}

///|
/// Reset the accumulations for a delta reader: the next collection describes
/// only what is written after this moment.
fn Instrument::reset(self : Instrument) -> Unit {
  self.series.val = []
}

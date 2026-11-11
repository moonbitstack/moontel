// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One series of one stream: its attribute set, when it began, and the accumulated
/// point that will be exported.
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
  /// What an observable instrument reported at the last export, so a delta reader
  /// sees the change rather than the total. Unused by the synchronous instruments,
  /// whose delta is the accumulation since the last export.
  reported : Double?
}

///|
/// One way of seeing an instrument: its name, its aggregation, which attributes
/// survive, and the series written under it.
///
/// An instrument with no view over it has one stream, which is the instrument as it
/// was registered. A view that renames it, aggregates it differently or drops some
/// attributes adds a stream of its own, so the same measurement can reach a backend
/// twice — once coarse and once fine — without being recorded twice.
pub struct Stream {
  name : String
  description : String
  aggregation : Aggregation
  attribute_keys : Array[String]?
  series : Array[Series]
}

///|
/// What every stream of one name shares.
pub struct Instrument {
  name : String
  description : String
  unit : String
  kind : InstrumentKind
  bounds : Array[Double]
  max_buckets : Int32
  limits : MeterLimits
  temporality : @otlp.Temporality
  exemplar : ExemplarFilter
  current : () -> @trace.TraceContext?
  now : () -> Int64
  start : Int64
  /// The callback an observable instrument reports through, run once per collection.
  observe : ((Observer) -> Unit)?
  streams : Array[Stream]
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
/// A distribution whose buckets adapt to the measurements.
pub struct ExponentialHistogram {
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
/// A monotonic sum whose value is reported when the metrics are collected.
pub struct ObservableCounter {
  provider : MeterProvider
  index : Int32
}

///|
/// A sum either sign of which is reported when the metrics are collected.
pub struct ObservableUpDownCounter {
  provider : MeterProvider
  index : Int32
}

///|
/// A value reported when the metrics are collected.
pub struct ObservableGauge {
  provider : MeterProvider
  index : Int32
}

///|
/// What an observable instrument's callback writes through.
///
/// The observer is handed to the callback at the moment of collection and is only
/// valid then: it writes into the series that collection is reading, so a value
/// reported while nothing is being collected would have nowhere to go. Keeping it a
/// value passed in — rather than a global the callback has to find — is what makes
/// two providers in one process independent.
pub struct Observer {
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
fn ExponentialHistogram::handle(self : ExponentialHistogram) -> Instrument {
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
  self.handle().write(value, attributes, at, context, observed=false)
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
  self.handle().write(value, attributes, at, context, observed=false)
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
  self.handle().write(value, attributes, at, context, observed=false)
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
  self.handle().write(value, attributes, at, context, observed=false)
}

///|
/// Record one measurement into the exponential bucket that contains it.
///
/// A bucket grows with the value it holds, so a millisecond and a minute are both
/// resolved finely with one set of buckets; when the measurements spread out enough
/// to need more than `max_buckets`, neighbouring buckets merge and the scale drops.
/// The scale a point was written at is on the point, so a reader never has to guess
/// it.
pub fn ExponentialHistogram::record(
  self : ExponentialHistogram,
  value : Double,
  attributes~ : Attributes = empty_attributes,
  at? : Int64,
  context? : @trace.TraceContext,
) -> Unit {
  if !finite(value) {
    return
  }
  self.handle().write(value, attributes, at, context, observed=false)
}

///|
/// Report the value of this series as it stands now.
///
/// The callback of an observable counter runs at each collection, and what it
/// observes replaces what was observed before: the value is a total, not an
/// increment. A delta reader is given the difference between two collections, which
/// is what makes an observed total usable by a scraper that wants per-interval
/// numbers.
pub fn Observer::observe(
  self : Observer,
  value : Double,
  attributes~ : Attributes = empty_attributes,
  at? : Int64,
  context? : @trace.TraceContext,
) -> Unit {
  if !finite(value) {
    return
  }
  self.provider.instruments.val[self.index].write(
    value,
    attributes,
    at,
    context,
    observed=true,
  )
}

///|
/// How many measurements this instrument refused because its cardinality limit
/// was reached.
fn Instrument::dropped(self : Instrument) -> Int32 {
  self.dropped.val
}

///|
/// Whether this instrument's values are reported at collection time.
fn Instrument::is_observable(self : Instrument) -> Bool {
  match self.kind {
    ObservableCounter | ObservableUpDownCounter | ObservableGauge => true
    _ => false
  }
}

///|
/// Write one measurement into every stream of this instrument.
fn Instrument::write(
  self : Instrument,
  value : Double,
  attributes : Attributes,
  at : Int64?,
  context : @trace.TraceContext?,
  observed~ : Bool,
) -> Unit {
  let at = at.unwrap_or((self.now)())
  let bounded = bounded_attributes(attributes, self.limits)
  // A measurement with no context of its own belongs to the span the program says it
  // is inside, which is what makes an exemplar the request that caused the number.
  let context = match context {
    Some(context) => Some(context)
    None => (self.current)()
  }
  let mut accepted = false
  for i in 0..<self.streams.length() {
    let stream = self.streams[i]
    let filtered = match stream.attribute_keys {
      Some(keys) => filter_attributes(bounded, keys)
      None => bounded
    }
    match
      stream.series_index(
        filtered,
        at,
        self.start,
        self.temporality,
        self.limits.series,
      ) {
      None => ()
      Some(slot) => {
        accepted = true
        let series = stream.series[slot]
        let point = stream.next_point(series.point, value, observed)
        stream.series[slot] = {
          ..series,
          point,
          exemplars: exemplars_of(
            series,
            value,
            at,
            context,
            filtered,
            self.exemplar,
            self.limits,
          ),
        }
      }
    }
  }
  if !accepted {
    self.dropped.val = self.dropped.val + 1
  }
}

///|
/// The point after one measurement.
fn Stream::next_point(
  self : Stream,
  point : @otlp.Point,
  value : Double,
  observed : Bool,
) -> @otlp.Point {
  match self.aggregation {
    Sum =>
      match point {
        // An observed value is a total the callback states, not an increment, so it
        // replaces what was there; a written value adds to it.
        @otlp.AsDouble(previous) =>
          @otlp.AsDouble(if observed { value } else { previous + value })
        other => other
      }
    LastValue => @otlp.AsDouble(value)
    ExplicitBuckets(_) =>
      match point {
        @otlp.Buckets(bounds~, counts~, sum~, count~, min~, max~) => {
          let slot = bucket_index(bounds, value)
          let next_counts = counts.copy()
          next_counts[slot] = next_counts[slot] + 1L
          @otlp.Buckets(
            bounds~,
            counts=next_counts,
            sum=sum + value,
            count=count + 1L,
            min=least(min, value),
            max=greatest(max, value),
          )
        }
        // A series is created with the point its stream needs, so this arm is
        // unreachable; keeping it makes the match total.
        other => other
      }
    ExponentialBuckets(max_buckets~, ..) =>
      exponential_record(point, value, max_buckets)
    Drop => point
  }
}

///|
fn least(current : Double?, value : Double) -> Double? {
  match current {
    Some(current) => Some(if value < current { value } else { current })
    None => Some(value)
  }
}

///|
fn greatest(current : Double?, value : Double) -> Double? {
  match current {
    Some(current) => Some(if value > current { value } else { current })
    None => Some(value)
  }
}

///|
/// The index of the series these attributes name, creating it when there is
/// room. `None` means the cardinality limit was reached and the measurement has
/// to be dropped rather than put in a series of its own.
fn Stream::series_index(
  self : Stream,
  attributes : Attributes,
  at : Int64,
  start : Int64,
  temporality : @otlp.Temporality,
  limit : Int32,
) -> Int32? {
  let key = attributes.identity()
  for i in 0..<self.series.length() {
    if self.series[i].key == key {
      return Some(i)
    }
  }
  if self.series.length() >= limit {
    return None
  }
  let start = if temporality == @otlp.Delta { at } else { start }
  self.series.push({
    attributes,
    key,
    start,
    point: initial_point(self.aggregation),
    exemplars: [],
    reported: None,
  })
  Some(self.series.length() - 1)
}

///|
/// The point a stream starts with, before any measurement.
fn initial_point(aggregation : Aggregation) -> @otlp.Point {
  match aggregation {
    ExplicitBuckets(bounds~) =>
      @otlp.Buckets(
        bounds=bounds.copy(),
        counts=empty_counts(bounds),
        sum=0.0,
        count=0L,
        min=None,
        max=None,
      )
    ExponentialBuckets(scale~, ..) => exponential_empty(scale)
    _ => @otlp.AsDouble(0.0)
  }
}

///|
/// Keep the most recent sampled trace beside the series, up to the limit.
///
/// An exemplar is what lets a reader jump from a slow bucket to the request that
/// filled it. Which measurements are worth keeping is a policy: by default only one
/// from a trace that was sampled and is a trace at all, because only those a backend
/// can look up.
fn exemplars_of(
  series : Series,
  value : Double,
  at : Int64,
  context : @trace.TraceContext?,
  attributes : Attributes,
  filter : ExemplarFilter,
  limits : MeterLimits,
) -> Array[@otlp.Exemplar] {
  let previous = series.exemplars.copy()
  if limits.exemplars <= 0 {
    return previous
  }
  let keep = match (filter, context) {
    (AlwaysOff, _) => false
    (TraceBased, Some(context)) => context.sampled() && context.is_valid()
    (TraceBased, None) => false
    (AlwaysOn, _) => true
  }
  if !keep {
    return previous
  }
  let (trace_id, span_id) = match context {
    Some(context) => (Some(context.trace_id), Some(context.span_id))
    None => ((None : Bytes?), (None : Bytes?))
  }
  previous.push({
    time: at,
    value,
    attributes: attributes.to_array(),
    trace_id,
    span_id,
  })
  keep_latest(previous, limits.exemplars)
}

///|
/// The last `keep` exemplars, so a series carries recent traces rather than the first
/// ones it ever saw.
fn keep_latest(
  values : Array[@otlp.Exemplar],
  keep : Int32,
) -> Array[@otlp.Exemplar] {
  let begin = if values.length() > keep { values.length() - keep } else { 0 }
  let recent : Array[@otlp.Exemplar] = []
  for i in begin..<values.length() {
    recent.push(values[i])
  }
  recent
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
/// The attributes a view keeps.
fn filter_attributes(
  attributes : Attributes,
  keys : Array[String],
) -> Attributes {
  let kept : Array[(String, @trace.Value)] = []
  for entry in attributes.entries {
    for key in keys {
      if key == entry.0 {
        kept.push(entry)
        break
      }
    }
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
/// One metric per stream, with the points collected at `at`.
fn Instrument::to_metrics(self : Instrument, at : Int64) -> Array[@otlp.Metric] {
  let metrics : Array[@otlp.Metric] = []
  for stream in self.streams {
    metrics.push({
      name: stream.name,
      description: stream.description,
      unit: self.unit,
      kind: metric_kind(stream.aggregation, self.kind, self.temporality),
      points: self.points_of(stream, at),
    })
  }
  metrics
}

///|
fn Instrument::points_of(
  self : Instrument,
  stream : Stream,
  at : Int64,
) -> Array[@otlp.DataPoint] {
  let points : Array[@otlp.DataPoint] = []
  for series in stream.series {
    let start = if stream.aggregation == LastValue {
      None
    } else if self.temporality == @otlp.Delta {
      Some(series.start)
    } else {
      Some(self.start)
    }
    points.push({
      attributes: series.attributes.to_array(),
      start,
      time: at,
      point: reported_point(series, stream.aggregation, self),
      exemplars: series.exemplars.copy(),
      flags: 0,
    })
  }
  points
}

///|
/// The point a reader sees: what was accumulated, or — for a value that is reported
/// as a total at each collection — the change since the last export.
fn reported_point(
  series : Series,
  aggregation : Aggregation,
  instrument : Instrument,
) -> @otlp.Point {
  if !instrument.is_observable() || instrument.temporality != @otlp.Delta {
    return series.point
  }
  match (aggregation, series.point) {
    (Sum, @otlp.AsDouble(total)) => {
      let previous = match series.reported {
        Some(previous) => previous
        None => 0.0
      }
      @otlp.AsDouble(total - previous)
    }
    _ => series.point
  }
}

///|
fn metric_kind(
  aggregation : Aggregation,
  kind : InstrumentKind,
  temporality : @otlp.Temporality,
) -> @otlp.MetricKind {
  match aggregation {
    Sum =>
      @otlp.Sum(
        temporality~,
        monotonic=match kind {
          Counter | ObservableCounter => true
          _ => false
        },
      )
    LastValue => @otlp.Gauge
    ExplicitBuckets(_) => @otlp.Histogram(temporality~)
    ExponentialBuckets(_) => @otlp.ExponentialHistogram(temporality~)
    Drop => @otlp.Gauge
  }
}

///|
/// Reset what a delta reader has already been given.
///
/// A written accumulation is cleared, so the next export describes only what came
/// after this one. An observed total cannot be cleared — the callback will state it
/// again — so the value it stated is remembered and the next export reports the
/// difference.
fn Instrument::reset(self : Instrument) -> Unit {
  for i in 0..<self.streams.length() {
    let stream = self.streams[i]
    if self.is_observable() {
      for j in 0..<stream.series.length() {
        let series = stream.series[j]
        let reported = match series.point {
          @otlp.AsDouble(value) => Some(value)
          _ => series.reported
        }
        stream.series[j] = { ..series, exemplars: [], reported, }
      }
    } else {
      stream.series.clear()
    }
  }
}

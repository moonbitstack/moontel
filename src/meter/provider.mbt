// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Where instruments are registered and where their accumulations are collected.
///
/// The provider holds no resource and no scope of its own: those belong to the
/// exporter, which is the same object a program already hands its spans and logs.
/// Metrics therefore travel under the same resource, the same transport, the same
/// batching and the same retry policy as the other two signals.
///
/// It reads no clock. `now` is the caller's, and `collect` is given the instant
/// the points are dated with, so a replay can produce the timeline it chooses.
pub struct MeterProvider {
  sink : &@otlp.MetricSink
  now : () -> Int64
  temporality : @otlp.Temporality
  limits : MeterLimits
  exemplar : ExemplarFilter
  current : () -> @trace.TraceContext?
  views : Array[View]
  start : Int64
  instruments : Ref[Array[Instrument]]
}

///|
/// The context a measurement belongs to when the caller gives none: there is not one.
fn no_context() -> @trace.TraceContext? {
  None
}

///|
/// A provider writing finished metrics to `sink`, timed by `now`.
///
/// `temporality` is the reader's choice: cumulative is what the OTLP exporters
/// of most backends want, delta is what a Prometheus-style scraper wants. `start`
/// is when the process began accumulating, in nanoseconds; it defaults to the
/// first reading of `now`.
///
/// `views` is how a program decides what the metrics look like without touching
/// the call sites — a name, a description, which attributes survive, how the
/// measurements are aggregated, or that an instrument is not wanted at all.
/// `exemplar` says which measurements are worth keeping beside a bucket, and
/// `current` says which span a measurement belongs to when the call site does not
/// name one: hand it the span the request is in, and an exemplar points at that
/// request.
pub fn MeterProvider::new(
  sink~ : &@otlp.MetricSink,
  now~ : () -> Int64,
  temporality~ : @otlp.Temporality = @otlp.Cumulative,
  limits~ : MeterLimits = meter_limits,
  exemplar~ : ExemplarFilter = TraceBased,
  current~ : () -> @trace.TraceContext? = no_context,
  views~ : Array[View] = [],
  start? : Int64,
) -> MeterProvider {
  {
    sink,
    now,
    temporality,
    limits,
    exemplar,
    current,
    views,
    start: start.unwrap_or(now()),
    instruments: Ref([]),
  }
}

///|
/// A meter naming the instrumentation scope its instruments belong to.
///
/// Several parts of a program can each have a meter. The scope is a local
/// identity — `scope` reads it back — while the name an exporter puts on the
/// wire is the exporter's own `scope~`; a program that needs two scope names on
/// the wire makes two providers and two exporters.
pub struct Meter {
  provider : MeterProvider
  scope : @otlp.Scope
}

///|
/// The meter for one library or one part of a program.
pub fn MeterProvider::meter(
  self : MeterProvider,
  name~ : String,
  version? : String,
  attributes~ : Array[(String, @trace.Value)] = [],
) -> Meter {
  { provider: self, scope: @otlp.Scope::new(name~, version?, attributes~), }
}

///|
/// The scope this meter names.
pub fn Meter::scope(self : Meter) -> @otlp.Scope {
  self.scope
}

///|
/// A monotonic sum, written as the program runs. `add` with a negative amount is
/// ignored.
pub fn Meter::counter(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
) -> Counter raise Refused {
  {
    provider: self.provider,
    index: self.register({
      name,
      description,
      unit,
      kind: Counter,
      bounds: [],
      scale: max_exponential_scale,
      max_buckets: max_exponential_buckets,
      observe: None,
    }),
  }
}

///|
/// A sum that may go up or down, written as the program runs.
pub fn Meter::up_down_counter(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
) -> UpDownCounter raise Refused {
  {
    provider: self.provider,
    index: self.register({
      name,
      description,
      unit,
      kind: UpDownCounter,
      bounds: [],
      scale: max_exponential_scale,
      max_buckets: max_exponential_buckets,
      observe: None,
    }),
  }
}

///|
/// A distribution over `bounds`, which default to the OpenTelemetry SDK's
/// explicit bucket boundaries. The unit on the instrument is the unit of every
/// boundary and of every recorded value.
pub fn Meter::histogram(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
  bounds~ : Array[Double] = default_buckets,
) -> Histogram raise Refused {
  {
    provider: self.provider,
    index: self.register({
      name,
      description,
      unit,
      kind: Histogram,
      bounds,
      scale: max_exponential_scale,
      max_buckets: max_exponential_buckets,
      observe: None,
    }),
  }
}

///|
/// A distribution whose buckets follow the measurements.
///
/// `scale` is where it starts — 20 is the finest the SDK defines, and each step
/// down halves the resolution and doubles what one bucket covers — and
/// `max_buckets` is how many buckets it may use before the scale drops, 160 by
/// default. The point carries the scale it ended at, so a reader never has to guess
/// what a bucket index means.
pub fn Meter::exponential_histogram(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
  scale? : Int32,
  max_buckets? : Int32,
) -> ExponentialHistogram raise Refused {
  {
    provider: self.provider,
    index: self.register({
      name,
      description,
      unit,
      kind: ExponentialHistogram,
      bounds: [],
      scale: clamp_scale(scale.unwrap_or(max_exponential_scale)),
      max_buckets: clamp_buckets(max_buckets.unwrap_or(max_exponential_buckets)),
      observe: None,
    }),
  }
}

///|
/// The most recent value of a series, written as the program runs.
pub fn Meter::gauge(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
) -> Gauge raise Refused {
  {
    provider: self.provider,
    index: self.register({
      name,
      description,
      unit,
      kind: Gauge,
      bounds: [],
      scale: max_exponential_scale,
      max_buckets: max_exponential_buckets,
      observe: None,
    }),
  }
}

///|
/// A monotonic sum whose value is reported when the metrics are collected.
///
/// The callback runs once per collection and reports the totals that are true at
/// that moment. A cumulative reader sees the total; a delta reader sees what
/// changed since the last export.
pub fn Meter::observable_counter(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
  observe~ : (Observer) -> Unit,
) -> ObservableCounter raise Refused {
  {
    provider: self.provider,
    index: self.register({
      name,
      description,
      unit,
      kind: ObservableCounter,
      bounds: [],
      scale: max_exponential_scale,
      max_buckets: max_exponential_buckets,
      observe: Some(observe),
    }),
  }
}

///|
/// A sum either sign of which is reported when the metrics are collected.
pub fn Meter::observable_up_down_counter(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
  observe~ : (Observer) -> Unit,
) -> ObservableUpDownCounter raise Refused {
  {
    provider: self.provider,
    index: self.register({
      name,
      description,
      unit,
      kind: ObservableUpDownCounter,
      bounds: [],
      scale: max_exponential_scale,
      max_buckets: max_exponential_buckets,
      observe: Some(observe),
    }),
  }
}

///|
/// A value reported when the metrics are collected, such as a queue depth or a
/// temperature: a number that is what it is rather than a total of anything.
pub fn Meter::observable_gauge(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
  observe~ : (Observer) -> Unit,
) -> ObservableGauge raise Refused {
  {
    provider: self.provider,
    index: self.register({
      name,
      description,
      unit,
      kind: ObservableGauge,
      bounds: [],
      scale: max_exponential_scale,
      max_buckets: max_exponential_buckets,
      observe: Some(observe),
    }),
  }
}

///|
/// The metrics as they stand, dated `at`, in registration order.
///
/// An observable instrument's callback is run first, because its value is defined
/// as what the callback says at that moment; every instrument then contributes one
/// metric per stream. Collection does not clear a cumulative reader's numbers, so
/// the same points can be read again or handed to more than one sink. `emit` is the
/// call that also writes them to the sink.
pub fn MeterProvider::collect(
  self : MeterProvider,
  at~ : Int64,
) -> Array[@otlp.Metric] {
  self.ask_callbacks()
  let metrics : Array[@otlp.Metric] = []
  for instrument in self.instruments.val {
    for metric in instrument.to_metrics(at) {
      metrics.push(metric)
    }
  }
  metrics
}

///|
/// Collect and hand every metric to the sink.
///
/// With delta temporality the accumulations are cleared afterwards, so one
/// measurement is never counted in two consecutive exports. With cumulative
/// temporality they are kept, and a restart of the process is what resets them.
pub fn MeterProvider::emit(
  self : MeterProvider,
  at~ : Int64,
) -> Array[@otlp.Metric] {
  let metrics = self.collect(at~)
  for metric in metrics {
    self.sink.accept(metric)
  }
  if self.temporality == @otlp.Delta {
    for instrument in self.instruments.val {
      instrument.reset()
    }
  }
  metrics
}

///|
/// Run every observable instrument's callback, so the collected points are the
/// values that hold at this moment.
fn MeterProvider::ask_callbacks(self : MeterProvider) -> Unit {
  // A copy, so a callback that registers an instrument does not change the list
  // being walked; an instrument registered during collection is collected next time.
  let instruments = self.instruments.val.copy()
  for i in 0..<instruments.length() {
    match instruments[i].observe {
      Some(callback) => callback({ provider: self, index: i, })
      None => ()
    }
  }
}

///|
/// Which temporality this provider exports.
pub fn MeterProvider::temporality(self : MeterProvider) -> @otlp.Temporality {
  self.temporality
}

///|
/// The limits this provider's instruments were built with.
pub fn MeterProvider::limits(self : MeterProvider) -> MeterLimits {
  self.limits
}

///|
/// Which measurements this provider keeps as exemplars.
pub fn MeterProvider::exemplar_filter(self : MeterProvider) -> ExemplarFilter {
  self.exemplar
}

///|
/// The views this provider applies to the instruments registered with it.
pub fn MeterProvider::views(self : MeterProvider) -> Array[View] {
  self.views.copy()
}

///|
/// How many instruments are registered.
pub fn MeterProvider::len(self : MeterProvider) -> Int32 {
  self.instruments.val.length()
}

///|
/// How many measurements were dropped because a cardinality limit was reached.
pub fn MeterProvider::dropped(self : MeterProvider) -> Int32 {
  let mut total = 0
  for instrument in self.instruments.val {
    total = total + instrument.dropped()
  }
  total
}

// ------------------------------------------------------------------ internals

///|
/// What an instrument is registered as.
priv struct Registration {
  name : String
  description : String
  unit : String
  kind : InstrumentKind
  bounds : Array[Double]
  scale : Int32
  max_buckets : Int32
  observe : ((Observer) -> Unit)?
}

///|
/// Register a name once.
///
/// Instrument names are case-insensitive in the specification, so `Requests`
/// and `requests` are the same instrument; the spelling of the first registration
/// is the one exported. Registering the same name as two different kinds is a
/// mistake the caller has to see, not one to paper over by silently changing the
/// series' meaning.
fn Meter::register(self : Meter, spec : Registration) -> Int32 raise Refused {
  validate_name(spec.name)
  match spec.kind {
    Histogram => validate_bounds(spec.bounds, spec.name)
    _ => ()
  }
  let folded = spec.name.to_lower()
  for i in 0..<self.provider.instruments.val.length() {
    let instrument = self.provider.instruments.val[i]
    if instrument.name.to_lower() == folded {
      if instrument.kind != spec.kind {
        raise Refused::Conflict(
          name=spec.name,
          got=instrument.kind,
          want=spec.kind,
        )
      }
      return i
    }
  }
  let instrument : Instrument = {
    name: spec.name,
    description: spec.description,
    unit: spec.unit,
    kind: spec.kind,
    bounds: spec.bounds,
    max_buckets: spec.max_buckets,
    limits: self.provider.limits,
    temporality: self.provider.temporality,
    exemplar: self.provider.exemplar,
    current: self.provider.current,
    now: self.provider.now,
    start: self.provider.start,
    observe: spec.observe,
    streams: [],
    dropped: Ref(0),
  }
  let resolved : Instrument = {
    ..instrument,
    streams: instrument.resolve_streams(self.provider.views, spec.scale),
  }
  self.provider.instruments.val.push(resolved)
  self.provider.instruments.val.length() - 1
}

///|
/// The streams a view asks for, or the instrument as it was registered when no view
/// selects it.
fn Instrument::resolve_streams(
  self : Instrument,
  views : Array[View],
  scale : Int32,
) -> Array[Stream] {
  let streams : Array[Stream] = []
  let mut dropped = false
  for view in views {
    if view.selects(self.name, self.kind) {
      let aggregation = match (view.aggregation, self.kind) {
        // A distribution cannot be observed: a callback states values, and a
        // histogram of values that are already aggregates measures nothing. The
        // instrument keeps its own aggregation, which is what the SDK does with an
        // aggregation that does not apply.
        (Some(ExplicitBuckets(_) | ExponentialBuckets(..)), kind) =>
          if is_observable_kind(kind) {
            self.default_aggregation(scale)
          } else {
            view.aggregation.unwrap()
          }
        (Some(aggregation), _) => aggregation
        (None, _) => self.default_aggregation(scale)
      }
      match aggregation {
        Drop => dropped = true
        aggregation =>
          streams.push({
            name: view.name.unwrap_or(self.name),
            description: view.description.unwrap_or(self.description),
            aggregation,
            attribute_keys: view.attribute_keys,
            series: [],
          })
      }
    }
  }
  if streams.is_empty() && !dropped {
    streams.push({
      name: self.name,
      description: self.description,
      aggregation: self.default_aggregation(scale),
      attribute_keys: None,
      series: [],
    })
  }
  streams
}

///|
/// The aggregation a stream of this instrument uses when no view changes it.
fn Instrument::default_aggregation(
  self : Instrument,
  scale : Int32,
) -> Aggregation {
  match self.kind {
    Histogram => ExplicitBuckets(bounds=self.bounds)
    ExponentialHistogram =>
      ExponentialBuckets(scale~, max_buckets=self.max_buckets)
    kind => default_aggregation(kind, self.bounds, self.max_buckets)
  }
}

///|
fn is_observable_kind(kind : InstrumentKind) -> Bool {
  match kind {
    ObservableCounter | ObservableUpDownCounter | ObservableGauge => true
    _ => false
  }
}

///|
fn clamp_scale(scale : Int32) -> Int32 {
  if scale > max_exponential_scale {
    max_exponential_scale
  } else if scale < min_exponential_scale {
    min_exponential_scale
  } else {
    scale
  }
}

///|
fn clamp_buckets(max_buckets : Int32) -> Int32 {
  if max_buckets < 2 {
    2
  } else if max_buckets > max_exponential_buckets {
    max_exponential_buckets
  } else {
    max_buckets
  }
}

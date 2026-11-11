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
  start : Int64
  instruments : Ref[Array[Instrument]]
}

///|
/// A provider writing finished metrics to `sink`, timed by `now`.
///
/// `temporality` is the reader's choice: cumulative is what the OTLP exporters
/// of most backends want, delta is what a Prometheus-style scraper wants. `start`
/// is when the process began accumulating, in nanoseconds; it defaults to the
/// first reading of `now`.
pub fn MeterProvider::new(
  sink~ : &@otlp.MetricSink,
  now~ : () -> Int64,
  temporality~ : @otlp.Temporality = @otlp.Cumulative,
  limits~ : MeterLimits = meter_limits,
  start? : Int64,
) -> MeterProvider {
  {
    sink,
    now,
    temporality,
    limits,
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
/// A monotonic sum. `add` with a negative amount is ignored.
pub fn Meter::counter(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
) -> Counter raise Refused {
  {
    provider: self.provider,
    index: self.register(name, description, unit, Counter, None),
  }
}

///|
/// A sum that may go up or down.
pub fn Meter::up_down_counter(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
) -> UpDownCounter raise Refused {
  {
    provider: self.provider,
    index: self.register(name, description, unit, UpDownCounter, None),
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
    index: self.register(name, description, unit, Histogram, Some(bounds)),
  }
}

///|
/// The most recent value of a series.
pub fn Meter::gauge(
  self : Meter,
  name : String,
  description~ : String = "",
  unit~ : String = "",
) -> Gauge raise Refused {
  {
    provider: self.provider,
    index: self.register(name, description, unit, Gauge, None),
  }
}

///|
/// The metrics accumulated so far, dated `at`, in registration order.
///
/// Collection does not change what a cumulative reader sees: the same points can
/// be collected again, or handed to more than one sink. `emit` is the call that
/// also writes them to the sink.
pub fn MeterProvider::collect(
  self : MeterProvider,
  at~ : Int64,
) -> Array[@otlp.Metric] {
  let metrics : Array[@otlp.Metric] = []
  for instrument in self.instruments.val {
    metrics.push(instrument.to_metric(at))
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
/// Register a name once.
///
/// Instrument names are case-insensitive in the specification, so `Requests`
/// and `requests` are the same instrument; the spelling of the first registration
/// is the one exported. Registering the same name as two different kinds is a
/// mistake the caller has to see, not one to paper over by silently changing the
/// series' meaning.
fn Meter::register(
  self : Meter,
  name : String,
  description : String,
  unit : String,
  kind : InstrumentKind,
  bounds : Array[Double]?,
) -> Int32 raise Refused {
  validate_name(name)
  match bounds {
    Some(bounds) => validate_bounds(bounds, name)
    None => ()
  }
  let folded = name.to_lower()
  for i in 0..<self.provider.instruments.val.length() {
    let instrument = self.provider.instruments.val[i]
    if instrument.name.to_lower() == folded {
      if instrument.kind != kind {
        raise Refused::Conflict(name~, got=instrument.kind, want=kind)
      }
      return i
    }
  }
  let instrument : Instrument = {
    name,
    description,
    unit,
    kind,
    bounds: bounds.unwrap_or([]),
    limits: self.provider.limits,
    temporality: self.provider.temporality,
    now: self.provider.now,
    start: self.provider.start,
    series: Ref([]),
    dropped: Ref(0),
  }
  self.provider.instruments.val.push(instrument)
  self.provider.instruments.val.length() - 1
}

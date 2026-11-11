// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn setup(
  limits~ : MeterLimits = meter_limits,
  temporality~ : @otlp.Temporality = @otlp.Cumulative,
) -> (MeterProvider, Meter) {
  let provider = MeterProvider::new(
    sink=@otlp.MetricRecorder::new(),
    now=() => 0L,
    start=10L,
    limits~,
    temporality~,
  )
  (provider, provider.meter(name="moontel-test"))
}

///|
fn sampled_context() -> @trace.TraceContext {
  @trace.TraceContext::new(
    trace_id=b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
    span_id=b"\x11\x12\x13\x14\x15\x16\x17\x18",
    flags=@trace.sampled_flag,
  )
}

///|
test "a counter adds to one series and refuses a negative amount" {
  let (provider, meter) = setup()
  let counter = meter.counter(
    "requests",
    description="Requests.",
    unit="{request}",
  )
  counter.add(3.0, at=20L)
  counter.inc(at=21L)
  counter.add(-1.0, at=22L)
  let metric = provider.collect(at=30L)[0]
  assert_eq(metric.name, "requests")
  assert_eq(metric.description, "Requests.")
  assert_eq(metric.unit, "{request}")
  assert_eq(metric.points.length(), 1)
  assert_eq(metric.points[0].point, @otlp.AsDouble(4.0))
  assert_eq(
    metric.kind,
    @otlp.Sum(temporality=@otlp.Cumulative, monotonic=true),
  )
  assert_eq(metric.points[0].start, Some(10L))
  assert_eq(metric.points[0].time, 30L)
}

///|
test "an up-down counter may go down and is exported as a non-monotonic sum" {
  let (provider, meter) = setup()
  let depth = meter.up_down_counter("queue.depth", unit="{job}")
  depth.add(5.0, at=20L)
  depth.add(-8.0, at=21L)
  let metric = provider.collect(at=30L)[0]
  assert_eq(metric.points[0].point, @otlp.AsDouble(-3.0))
  assert_eq(
    metric.kind,
    @otlp.Sum(temporality=@otlp.Cumulative, monotonic=false),
  )
}

///|
test "a gauge keeps the last value and has no start of accumulation" {
  let (provider, meter) = setup()
  let temperature = meter.gauge("temperature", unit="Cel")
  temperature.set(21.5, at=20L)
  temperature.set(22.0, at=21L)
  let metric = provider.collect(at=30L)[0]
  assert_eq(metric.points[0].point, @otlp.AsDouble(22.0))
  assert_eq(metric.kind, @otlp.Gauge)
  assert_eq(metric.points[0].start, None)
}

///|
test "a histogram fills the default buckets and keeps sum, count, min and max" {
  let (provider, meter) = setup()
  let duration = meter.histogram("gen_ai.client.operation.duration", unit="s")
  duration.record(0.0, at=20L)
  duration.record(5.0, at=21L)
  duration.record(6.0, at=22L)
  duration.record(10001.0, at=23L)
  let metric = provider.collect(at=30L)[0]
  assert_eq(metric.kind, @otlp.Histogram(temporality=@otlp.Cumulative))
  match metric.points[0].point {
    @otlp.Buckets(bounds~, counts~, sum~, count~, min~, max~) => {
      assert_eq(bounds, default_buckets)
      assert_eq(counts, [
        1L, 1L, 1L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 1L,
      ])
      assert_eq(sum, 10012.0)
      assert_eq(count, 4L)
      assert_eq(min, Some(0.0))
      assert_eq(max, Some(10001.0))
    }
    _ => fail("a histogram did not export buckets")
  }
}

///|
test "a histogram with custom bounds uses them" {
  let (provider, meter) = setup()
  let duration = meter.histogram("duration", bounds=[0.5, 1.0])
  duration.record(0.75)
  duration.record(2.0)
  match provider.collect(at=30L)[0].points[0].point {
    @otlp.Buckets(bounds~, counts~, ..) => {
      assert_eq(bounds, [0.5, 1.0])
      assert_eq(counts, [0L, 1L, 1L])
    }
    _ => fail("a histogram did not export buckets")
  }
}

///|
test "one attribute set is one series, and a second set is a second series" {
  let (provider, meter) = setup()
  let hits = meter.counter("hits")
  let first = Attributes::new(entries=[("route", @trace.Str("/orders"))])
  let second = Attributes::new(entries=[("route", @trace.Str("/cart"))])
  hits.inc(attributes=first)
  hits.inc(attributes=first)
  hits.inc(attributes=second)
  let metric = provider.collect(at=30L)[0]
  assert_eq(metric.points.length(), 2)
  // Series keep the order they were first written in, not the order of their
  // keys, so a collection is reproducible without sorting it again.
  assert_eq(metric.points[0].attributes, [("route", @trace.Str("/orders"))])
  assert_eq(metric.points[0].point, @otlp.AsDouble(2.0))
  assert_eq(metric.points[1].attributes, [("route", @trace.Str("/cart"))])
  assert_eq(metric.points[1].point, @otlp.AsDouble(1.0))
}

///|
test "a sampled context is kept as an exemplar, an unsampled one is not" {
  let (provider, meter) = setup()
  let hits = meter.counter("hits")
  let sampled = sampled_context()
  hits.inc(context=sampled, at=20L)
  hits.inc(
    at=21L,
    context=@trace.TraceContext::new(
      trace_id=sampled.trace_id,
      span_id=sampled.span_id,
      flags=b'\x00',
    ),
  )
  let point = provider.collect(at=30L)[0].points[0]
  assert_eq(point.exemplars.length(), 1)
  assert_eq(point.exemplars[0].trace_id, Some(sampled.trace_id))
  assert_eq(point.exemplars[0].span_id, Some(sampled.span_id))
  assert_eq(point.exemplars[0].value, 1.0)
}

///|
test "the cardinality limit drops a new series rather than growing without bound" {
  let (provider, meter) = setup(limits=MeterLimits::new(series=1))
  let hits = meter.counter("hits")
  hits.inc(attributes=Attributes::new(entries=[("route", @trace.Str("a"))]))
  hits.inc(attributes=Attributes::new(entries=[("route", @trace.Str("b"))]))
  assert_eq(provider.collect(at=30L)[0].points.length(), 1)
  assert_eq(provider.dropped(), 1)
}

///|
test "a name with dots is accepted and one outside the grammar is refused" {
  let (provider, meter) = setup()
  let _ = meter.histogram("gen_ai.client.operation.duration")
  assert_eq(
    provider.collect(at=30L)[0].name,
    "gen_ai.client.operation.duration",
  )
  let refused = try {
    meter.counter("1requests") |> ignore
    false
  } catch {
    Refused::InvalidName(..) => true
    _ => false
  }
  assert_true(refused)
  let empty = try {
    meter.counter("") |> ignore
    false
  } catch {
    Refused::EmptyName => true
    _ => false
  }
  assert_true(empty)
  assert_eq(is_valid_name("gen_ai.client.operation.duration"), true)
  assert_eq(is_valid_name("http/server.requests-2"), true)
  assert_eq(is_valid_name("a b"), false)
  assert_eq(is_valid_name("2bad"), false)
}

///|
test "a name is case-insensitive and cannot be two kinds of instrument" {
  let (provider, meter) = setup()
  let first = meter.counter("Requests")
  let second = meter.counter("requests")
  first.inc()
  second.inc()
  assert_eq(provider.len(), 1)
  assert_eq(provider.collect(at=30L)[0].name, "Requests")
  assert_eq(provider.collect(at=30L)[0].points[0].point, @otlp.AsDouble(2.0))
  let conflict = try {
    meter.histogram("requests") |> ignore
    false
  } catch {
    Refused::Conflict(got~, want~, ..) => got == Counter && want == Histogram
    _ => false
  }
  assert_true(conflict)
}

///|
test "bucket boundaries must be finite and strictly increasing" {
  let (_, meter) = setup()
  let repeated = try {
    meter.histogram("duration", bounds=[1.0, 1.0]) |> ignore
    false
  } catch {
    Refused::Bounds(at~, ..) => at == 1
    _ => false
  }
  assert_true(repeated)
  let empty = try {
    meter.histogram("other", bounds=[]) |> ignore
    false
  } catch {
    Refused::Bounds(at~, ..) => at == 0
    _ => false
  }
  assert_true(empty)
}

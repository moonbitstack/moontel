// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn exemplar_provider(
  filter : ExemplarFilter,
  current? : () -> @trace.TraceContext?,
) -> (MeterProvider, Meter) {
  let provider = MeterProvider::new(
    sink=@otlp.MetricRecorder::new(),
    now=() => 0L,
    exemplar=filter,
    current=current.unwrap_or(fn() { None }),
  )
  (provider, provider.meter(name="moontel-test"))
}

///|
fn unsampled_context() -> @trace.TraceContext {
  @trace.TraceContext::new(
    trace_id=b"\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30",
    span_id=b"\x31\x32\x33\x34\x35\x36\x37\x38",
    flags=b'\x00',
  )
}

///|
test "a valid context that was not sampled names a span nobody kept, so it is no exemplar" {
  let provider = MeterProvider::new(
    sink=@otlp.MetricRecorder::new(),
    now=() => 0L,
    limits=MeterLimits::new(exemplars=2),
  )
  let meter = provider.meter(name="moontel-test")
  let hits = meter.counter("hits")
  hits.inc(at=1L, context=unsampled_context())
  hits.inc(at=2L, context=sampled_context())
  let point = provider.collect(at=10L)[0].points[0]
  assert_eq(point.exemplars.length(), 1)
  assert_eq(point.exemplars[0].trace_id, Some(sampled_context().trace_id))
}

///|
test "the trace-based filter keeps a sampled trace and nothing else" {
  let (provider, meter) = exemplar_provider(TraceBased)
  let hits = meter.counter("hits")
  hits.inc(at=1L, context=sampled_context())
  hits.inc(at=2L, context=unsampled_context())
  hits.inc(at=3L)
  let point = provider.collect(at=10L)[0].points[0]
  assert_eq(point.exemplars.length(), 1)
  assert_eq(point.exemplars[0].trace_id, Some(sampled_context().trace_id))
}

///|
test "always on keeps a measurement no sampler agreed to keep" {
  let (provider, meter) = exemplar_provider(AlwaysOn)
  let hits = meter.counter("hits")
  hits.inc(at=1L, context=unsampled_context())
  let point = provider.collect(at=10L)[0].points[0]
  assert_eq(point.exemplars.length(), 1)
  assert_eq(point.exemplars[0].span_id, Some(unsampled_context().span_id))
}

///|
test "always off keeps none of them" {
  let (provider, meter) = exemplar_provider(AlwaysOff)
  let hits = meter.counter("hits")
  hits.inc(at=1L, context=sampled_context())
  let point = provider.collect(at=10L)[0].points[0]
  assert_eq(point.exemplars.length(), 0)
}

///|
test "a measurement with no span behind it is still a sample, with no ids" {
  let (provider, meter) = exemplar_provider(AlwaysOn)
  let hits = meter.counter("hits")
  hits.inc(at=1L)
  let point = provider.collect(at=10L)[0].points[0]
  assert_eq(point.exemplars.length(), 1)
  assert_eq(point.exemplars[0].trace_id, None)
  assert_eq(point.exemplars[0].span_id, None)
  assert_eq(point.exemplars[0].value, 1.0)
  assert_eq(point.exemplars[0].time, 1L)
}

///|
test "the current span is the context a measurement does not name" {
  let (provider, meter) = exemplar_provider(TraceBased, current=fn() {
    Some(sampled_context())
  })
  let hits = meter.counter("hits")
  hits.inc(at=1L)
  let point = provider.collect(at=10L)[0].points[0]
  assert_eq(point.exemplars.length(), 1)
  assert_eq(point.exemplars[0].trace_id, Some(sampled_context().trace_id))
}

///|
test "an exemplar carries the attributes of the measurement that filled the bucket" {
  let (provider, meter) = exemplar_provider(TraceBased)
  let hits = meter.counter("hits")
  hits.inc(
    at=1L,
    context=sampled_context(),
    attributes=Attributes::new(entries=[("route", @trace.Str("/orders"))]),
  )
  let exemplar = provider.collect(at=10L)[0].points[0].exemplars[0]
  assert_eq(exemplar.attributes, [("route", @trace.Str("/orders"))])
}

///|
test "one series keeps the most recent samples and no more than the limit allows" {
  let provider = MeterProvider::new(
    sink=@otlp.MetricRecorder::new(),
    now=() => 0L,
    limits=MeterLimits::new(exemplars=2),
  )
  let meter = provider.meter(name="moontel-test")
  let hits = meter.counter("hits")
  for i in 1..<=4 {
    hits.inc(at=i.to_int64(), context=sampled_context())
  }
  let point = provider.collect(at=10L)[0].points[0]
  assert_eq(point.exemplars.length(), 2)
  assert_eq(point.exemplars[0].time, 3L)
  assert_eq(point.exemplars[1].time, 4L)
}

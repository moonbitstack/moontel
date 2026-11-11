// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "an observable counter reports nothing until the metrics are collected" {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(sink=recorder, now=() => 0L)
  let meter = provider.meter(name="moontel-test")
  let reads = Ref(0)
  let jobs = meter.observable_counter("jobs.processed", unit="{job}", observe=fn(
    observer,
  ) {
    reads.val = reads.val + 1
    observer.observe(
      42.0,
      attributes=Attributes::new(entries=[("queue", @trace.Str("mail"))]),
    )
  })
  let _ = jobs
  assert_eq(reads.val, 0)
  let first = provider.collect(at=10L)
  assert_eq(reads.val, 1)
  assert_eq(first[0].name, "jobs.processed")
  assert_eq(first[0].kind, @otlp.Sum(temporality=Cumulative, monotonic=true))
  assert_eq(first[0].points[0].point, @otlp.AsDouble(42.0))
  assert_eq(first[0].points[0].attributes, [("queue", @trace.Str("mail"))])
}

///|
test "a cumulative observable counter reports the total the callback states" {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(sink=recorder, now=() => 0L)
  let meter = provider.meter(name="moontel-test")
  let total = Ref(10.0)
  let _ = meter.observable_counter("jobs.processed", observe=fn(observer) {
    observer.observe(total.val)
  })
  assert_eq(provider.collect(at=10L)[0].points[0].point, @otlp.AsDouble(10.0))
  total.val = 12.0
  assert_eq(provider.collect(at=20L)[0].points[0].point, @otlp.AsDouble(12.0))
}

///|
test "a delta reader of an observable counter sees the change, not the total" {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(
    sink=recorder,
    now=() => 0L,
    temporality=@otlp.Delta,
  )
  let meter = provider.meter(name="moontel-test")
  let total = Ref(10.0)
  let _ = meter.observable_counter("jobs.processed", observe=fn(observer) {
    observer.observe(total.val)
  })
  let first = provider.emit(at=10L)
  assert_eq(first[0].points[0].point, @otlp.AsDouble(10.0))
  total.val = 12.0
  let second = provider.emit(at=20L)
  assert_eq(second[0].points[0].point, @otlp.AsDouble(2.0))
  let third = provider.emit(at=30L)
  // Nothing changed, so nothing was added: the callback still states 12.
  assert_eq(third[0].points[0].point, @otlp.AsDouble(0.0))
}

///|
test "an observable gauge keeps the value the callback states, with no start" {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(sink=recorder, now=() => 0L, start=5L)
  let meter = provider.meter(name="moontel-test")
  let depth = Ref(7.0)
  let _ = meter.observable_gauge("queue.depth", unit="{request}", observe=fn(
    observer,
  ) {
    observer.observe(depth.val)
  })
  let metric = provider.collect(at=10L)[0]
  assert_eq(metric.kind, @otlp.Gauge)
  assert_eq(metric.points[0].point, @otlp.AsDouble(7.0))
  assert_eq(metric.points[0].start, None)
  depth.val = 3.0
  assert_eq(provider.collect(at=20L)[0].points[0].point, @otlp.AsDouble(3.0))
}

///|
test "an observable up-down counter may report a negative value" {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(sink=recorder, now=() => 0L)
  let meter = provider.meter(name="moontel-test")
  let _ = meter.observable_up_down_counter("workers.active", observe=fn(
    observer,
  ) {
    observer.observe(-2.0)
  })
  let metric = provider.collect(at=10L)[0]
  assert_eq(metric.points[0].point, @otlp.AsDouble(-2.0))
  assert_eq(metric.kind, @otlp.Sum(temporality=Cumulative, monotonic=false))
}

///|
test "one callback states several series and they stay apart" {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(sink=recorder, now=() => 0L)
  let meter = provider.meter(name="moontel-test")
  let _ = meter.observable_gauge("pool.size", observe=fn(observer) {
    observer.observe(
      4.0,
      attributes=Attributes::new(entries=[("pool", @trace.Str("read"))]),
    )
    observer.observe(
      2.0,
      attributes=Attributes::new(entries=[("pool", @trace.Str("write"))]),
    )
  })
  let metric = provider.collect(at=10L)[0]
  assert_eq(metric.points.length(), 2)
  assert_eq(metric.points[0].attributes, [("pool", @trace.Str("read"))])
  assert_eq(metric.points[0].point, @otlp.AsDouble(4.0))
  assert_eq(metric.points[1].point, @otlp.AsDouble(2.0))
}

///|
test "the callback runs once per instrument at each collection" {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(sink=recorder, now=() => 0L)
  let meter = provider.meter(name="moontel-test")
  let reads = Ref(0)
  let _ = meter.observable_counter("one", observe=fn(observer) {
    reads.val = reads.val + 1
    observer.observe(1.0)
  })
  let _ = meter.observable_gauge("two", observe=fn(observer) {
    observer.observe(2.0)
  })
  let _ = provider.collect(at=10L)
  assert_eq(reads.val, 1)
  let _ = provider.collect(at=20L)
  assert_eq(reads.val, 2)
}

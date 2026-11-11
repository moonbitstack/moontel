// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn view_provider(views : Array[View]) -> (MeterProvider, Meter) {
  let provider = MeterProvider::new(
    sink=@otlp.MetricRecorder::new(),
    now=() => 0L,
    views~,
  )
  (provider, provider.meter(name="moontel-test"))
}

///|
test "a view renames a metric and replaces its description" {
  let (provider, meter) = view_provider([
    View::new(
      instrument="requests",
      name="http.server.requests",
      description="Served.",
    ),
  ])
  let counter = meter.counter("requests", description="Requests.")
  counter.inc(at=1L)
  let metric = provider.collect(at=10L)[0]
  assert_eq(metric.name, "http.server.requests")
  assert_eq(metric.description, "Served.")
}

///|
test "a view keeps only the attributes it names" {
  let (provider, meter) = view_provider([
    View::new(instrument="hits", attribute_keys=["route"]),
  ])
  let hits = meter.counter("hits")
  hits.inc(
    at=1L,
    attributes=Attributes::new(entries=[
      ("route", @trace.Str("/orders")),
      ("user.id", @trace.Str("u-1")),
    ]),
  )
  hits.inc(
    at=2L,
    attributes=Attributes::new(entries=[
      ("route", @trace.Str("/orders")),
      ("user.id", @trace.Str("u-2")),
    ]),
  )
  let metric = provider.collect(at=10L)[0]
  // The dropped key was the only thing telling the two requests apart, so they are
  // one series and the number is the sum of both.
  assert_eq(metric.points.length(), 1)
  assert_eq(metric.points[0].attributes, [("route", @trace.Str("/orders"))])
  assert_eq(metric.points[0].point, @otlp.AsDouble(2.0))
}

///|
test "an empty attribute list keeps none of them" {
  let (provider, meter) = view_provider([
    View::new(instrument="hits", attribute_keys=[]),
  ])
  let hits = meter.counter("hits")
  hits.inc(
    at=1L,
    attributes=Attributes::new(entries=[("route", @trace.Str("/orders"))]),
  )
  assert_eq(provider.collect(at=10L)[0].points[0].attributes, [])
}

///|
test "a view that drops an instrument leaves it off the wire but registered" {
  let (provider, meter) = view_provider([
    View::new(instrument="debug.tick", aggregation=Drop),
  ])
  let tick = meter.counter("debug.tick")
  tick.inc(at=1L)
  let kept = meter.counter("kept")
  kept.inc(at=1L)
  let metrics = provider.collect(at=10L)
  assert_eq(provider.len(), 2)
  assert_eq(metrics.length(), 1)
  assert_eq(metrics[0].name, "kept")
}

///|
test "two views of one instrument are two metrics" {
  let (provider, meter) = view_provider([
    View::new(instrument="latency", name="latency.fine"),
    View::new(instrument="latency", name="latency.coarse", attribute_keys=[]),
  ])
  let latency = meter.histogram("latency", bounds=[1.0, 2.0])
  latency.record(
    1.5,
    at=1L,
    attributes=Attributes::new(entries=[("route", @trace.Str("/orders"))]),
  )
  let metrics = provider.collect(at=10L)
  assert_eq(metrics.length(), 2)
  assert_eq(metrics[0].name, "latency.fine")
  assert_eq(metrics[0].points[0].attributes, [("route", @trace.Str("/orders"))])
  assert_eq(metrics[1].name, "latency.coarse")
  assert_eq(metrics[1].points[0].attributes, [])
  match (metrics[0].points[0].point, metrics[1].points[0].point) {
    (@otlp.Buckets(count=first, ..), @otlp.Buckets(count=second, ..)) => {
      assert_eq(first, 1L)
      assert_eq(second, 1L)
    }
    _ => fail("both streams are histograms")
  }
}

///|
test "a wildcard view catches every instrument and a kind narrows it" {
  let (provider, meter) = view_provider([
    View::new(instrument="*", kind=Counter, name="counted"),
  ])
  let counter = meter.counter("requests")
  counter.inc(at=1L)
  let gauge = meter.gauge("temperature")
  gauge.set(21.0, at=1L)
  let metrics = provider.collect(at=10L)
  assert_eq(metrics[0].name, "counted")
  assert_eq(metrics[1].name, "temperature")
}

///|
test "a view that names no instrument but asks for a histogram does not touch a gauge" {
  let (provider, meter) = view_provider([
    View::new(
      instrument="temperature",
      aggregation=ExplicitBuckets(bounds=[1.0]),
    ),
  ])
  let temperature = meter.gauge("temperature")
  temperature.set(21.0, at=1L)
  let metric = provider.collect(at=10L)[0]
  assert_eq(metric.kind, @otlp.Histogram(temporality=Cumulative))
  // The measurement went into the bucket above 1.0, which is the point of letting a
  // view choose the aggregation.
  match metric.points[0].point {
    @otlp.Buckets(counts~, ..) => assert_eq(counts, [0L, 1L])
    _ => fail("the view did not change the aggregation")
  }
}

///|
test "a distribution is not applied to an instrument that is observed" {
  let (provider, meter) = view_provider([
    View::new(
      instrument="queue.depth",
      aggregation=ExplicitBuckets(bounds=[1.0]),
    ),
  ])
  let _ = meter.observable_gauge("queue.depth", observe=fn(observer) {
    observer.observe(7.0)
  })
  let metric = provider.collect(at=10L)[0]
  assert_eq(metric.kind, @otlp.Gauge)
  assert_eq(metric.points[0].point, @otlp.AsDouble(7.0))
}

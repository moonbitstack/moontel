// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The metric named `name` in a bridged snapshot, or `None`.
fn named(metrics : Array[@otlp.Metric], name : String) -> @otlp.Metric? {
  for metric in metrics {
    if metric.name == name {
      return Some(metric)
    }
  }
  None
}

///|
test "a counter becomes a cumulative monotonic sum under the name it had" {
  let registry = @metric.Registry::new()
  let counter = registry.counter("http_requests", "HTTP requests.")
  counter.inc(by=2.0)
  let metrics = bridge(
    registry.collect(at=1700000000.0),
    at=1700000000000000000L,
  )
  let metric = named(metrics, "http_requests").unwrap()
  assert_eq(metric.kind, @otlp.Sum(temporality=Cumulative, monotonic=true))
  // The compatibility rules say the Prometheus name is used as it stands.
  assert_eq(metric.name, "http_requests")
  assert_eq(metric.description, "HTTP requests.")
  assert_eq(metric.unit, "")
  assert_eq(metric.points.length(), 1)
  assert_eq(metric.points[0].point, @otlp.AsDouble(2.0))
  // A point with no timestamp of its own is dated when the snapshot was taken.
  assert_eq(metric.points[0].time, 1700000000000000000L)
}

///|
test "a gauge stays a gauge" {
  let registry = @metric.Registry::new()
  registry.gauge("queue_depth", "Jobs waiting.").set(7.0)
  let metrics = bridge(registry.collect(at=0.0), at=0L)
  let metric = named(metrics, "queue_depth").unwrap()
  assert_eq(metric.kind, @otlp.Gauge)
  assert_eq(metric.points[0].point, @otlp.AsDouble(7.0))
}

///|
test "a histogram becomes one count per bucket and one more count than bounds" {
  let registry = @metric.Registry::new()
  let histogram = registry.histogram("request_latency", "Latency.", buckets=[
    0.5, 1.0,
  ])
  histogram.observe(0.3)
  histogram.observe(0.7)
  histogram.observe(2.0)
  let metrics = bridge(registry.collect(at=0.0), at=0L)
  let metric = named(metrics, "request_latency").unwrap()
  assert_eq(metric.kind, @otlp.Histogram(temporality=Cumulative))
  match metric.points[0].point {
    @otlp.Buckets(bounds~, counts~, sum~, count~, ..) => {
      assert_eq(bounds, [0.5, 1.0])
      // The Prometheus snapshot counts 1 then 2 over the bounds; the third count is
      // the observation above the last bound.
      assert_eq(counts, [1L, 1L, 1L])
      assert_eq(count, 3L)
      assert_eq(sum, 3.0)
    }
    other => fail("expected buckets, got \{other.to_repr()}")
  }
}

///|
test "a summary keeps its quantiles" {
  let registry = @metric.Registry::new()
  let summary = @metric.Summary::new(quantiles=[(0.5, 0.05)])
  summary.observe(0.5)
  summary.observe(1.5)
  registry.register("latency_summary", "Latency.", summary)
  let metrics = bridge(registry.collect(at=0.0), at=0L)
  let metric = named(metrics, "latency_summary").unwrap()
  assert_eq(metric.kind, @otlp.Summary)
  match metric.points[0].point {
    @otlp.Quantiles(quantiles~, count~, ..) => {
      assert_eq(count, 2L)
      assert_eq(quantiles.length(), 1)
      assert_eq(quantiles[0].0, 0.5)
    }
    other => fail("expected quantiles, got \{other.to_repr()}")
  }
}

///|
test "an info metric is a non-monotonic sum that always reads one" {
  let registry = @metric.Registry::new()
  registry.register(
    "build_info",
    "Build info.",
    @metric.Info::new([("version", "1.2.3")]),
  )
  let metrics = bridge(registry.collect(at=0.0), at=0L)
  let metric = named(metrics, "build_info").unwrap()
  assert_eq(metric.kind, @otlp.Sum(temporality=Cumulative, monotonic=false))
  assert_eq(metric.points[0].attributes[0], ("version", @trace.Str("1.2.3")))
  assert_eq(metric.points[0].point, @otlp.AsDouble(1.0))
}

///|
test "a state set is one point per state, each naming itself" {
  let registry = @metric.Registry::new()
  let states = @metric.StateSet::new(["starting", "running", "stopped"])
  states.set("running")
  registry.register("task_state", "Task state.", states)
  let metrics = bridge(registry.collect(at=0.0), at=0L)
  let metric = named(metrics, "task_state").unwrap()
  assert_eq(metric.kind, @otlp.Sum(temporality=Cumulative, monotonic=false))
  assert_eq(metric.points.length(), 3)
  let mut running = 0.0
  for point in metric.points {
    let name = match point.attributes[0] {
      (key, @trace.Str(value)) if key == "state" => value
      _ => ""
    }
    match point.point {
      @otlp.AsDouble(value) => if name == "running" { running = value }
      _ => ()
    }
  }
  assert_eq(running, 1.0)
}

///|
test "a gauge histogram has no OTLP instrument and is dropped" {
  let registry = @metric.Registry::new()
  registry.register(
    "samples",
    "Samples.",
    @metric.GaugeHistogram::new(buckets=[1.0]),
  )
  registry.gauge("kept", "Kept.").set(1.0)
  let metrics = bridge(registry.collect(at=0.0), at=0L)
  assert_eq(named(metrics, "samples"), None)
  assert_true(named(metrics, "kept") is Some(_))
}

///|
test "a unit the compatibility table names travels as its UCUM code" {
  let registry = @metric.Registry::new()
  ignore(registry.counter("bytes_written", "Written.", unit="bytes"))
  ignore(registry.counter("uptime", "Uptime.", unit="seconds"))
  ignore(registry.counter("widgets", "Widgets.", unit="widgets"))
  let metrics = bridge(registry.collect(at=0.0), at=0L)
  // The metric keeps the name it was registered under, suffix and all: the
  // compatibility rules do not let a converter rename a Prometheus metric.
  assert_eq(named(metrics, "bytes_written_bytes").unwrap().unit, "By")
  assert_eq(named(metrics, "uptime_seconds").unwrap().unit, "s")
  // A unit the table does not know is not a unit this library may invent.
  assert_eq(named(metrics, "widgets_widgets").unwrap().unit, "widgets")
}

///|
test "a point keeps the timestamp and the exemplar it came with" {
  let registry = @metric.Registry::new()
  let counter = registry.counter("http_requests", "HTTP requests.")
  counter.inc(
    by=1.0,
    exemplar=@metric.Exemplar::new(
      [("route", "/orders")],
      1.0,
      timestamp=1700000000.5,
    ),
  )
  let metrics = bridge(registry.collect(at=0.0), at=0L)
  let metric = named(metrics, "http_requests").unwrap()
  assert_eq(metric.points[0].exemplars.length(), 1)
  assert_eq(metric.points[0].exemplars[0].time, 1700000000500000000L)
  assert_eq(
    metric.points[0].exemplars[0].attributes[0],
    ("route", @trace.Str("/orders")),
  )
}

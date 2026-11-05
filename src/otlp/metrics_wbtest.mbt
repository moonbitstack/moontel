// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn metric_of(point : DataPoint) -> Metric {
  {
    name: "queue.depth",
    description: "Jobs waiting.",
    unit: "{job}",
    kind: Gauge,
    points: [point],
  }
}

///|
fn gauge_metric(point : Point) -> Metric {
  metric_of({
    attributes: [],
    start: None,
    time: 5L,
    point,
    exemplars: [],
    flags: 0,
  })
}

///|
test "a gauge carries its description, its unit and an asDouble point" {
  let body = encode_metrics([gauge_metric(AsDouble(1.5))])
  assert_true(body.contains("\"name\":\"queue.depth\""))
  assert_true(body.contains("\"description\":\"Jobs waiting.\""))
  assert_true(body.contains("\"unit\":\"{job}\""))
  assert_true(
    body.contains(
      "\"gauge\":{\"dataPoints\":[{\"timeUnixNano\":\"5\",\"asDouble\":1.5}]}",
    ),
  )
}

///|
test "a monotonic cumulative sum says so, and a delta sum says delta" {
  let cumulative = encode_metrics([
    {
      ..gauge_metric(AsInt(4L)),
      kind: Sum(temporality=Cumulative, monotonic=true),
    },
  ])
  assert_true(cumulative.contains("\"asInt\":\"4\""))
  assert_true(cumulative.contains("\"aggregationTemporality\":2"))
  assert_true(cumulative.contains("\"isMonotonic\":true"))
  let delta = encode_metrics([
    { ..gauge_metric(AsInt(4L)), kind: Sum(temporality=Delta, monotonic=true), },
  ])
  assert_true(delta.contains("\"aggregationTemporality\":1"))
}

///|
test "a non-monotonic sum leaves the monotonic flag out, because false is the default" {
  let body = encode_metrics([
    {
      ..gauge_metric(AsDouble(1.0)),
      kind: Sum(temporality=Cumulative, monotonic=false),
    },
  ])
  assert_false(body.contains("isMonotonic"))
}

///|
test "a histogram states its bounds and one more count than there are bounds" {
  let body = encode_metrics([
    {
      ..gauge_metric(
        Buckets(
          bounds=[0.5, 1.0],
          counts=[1L, 2L, 3L],
          sum=2.5,
          count=6L,
          min=None,
          max=None,
        ),
      ),
      kind: Histogram(temporality=Cumulative),
    },
  ])
  assert_true(body.contains("\"count\":\"6\""))
  assert_true(body.contains("\"sum\":2.5"))
  assert_true(body.contains("\"bucketCounts\":[\"1\",\"2\",\"3\"]"))
  assert_true(body.contains("\"explicitBounds\":[0.5,1]"))
  assert_true(body.contains("\"aggregationTemporality\":2"))
}

///|
test "a summary states its quantiles" {
  let body = encode_metrics([
    {
      ..gauge_metric(
        Quantiles(quantiles=[(0.5, 1.0), (0.99, 9.0)], sum=10.0, count=2L),
      ),
      kind: Summary,
    },
  ])
  assert_true(
    body.contains(
      "\"quantileValues\":[{\"quantile\":0.5,\"value\":1},{\"quantile\":0.99,\"value\":9}]",
    ),
  )
  assert_true(body.contains("\"count\":\"2\""))
}

///|
test "a data point carries the start of its accumulation and its exemplars" {
  let body = encode_metrics([
    metric_of({
      attributes: [],
      start: Some(1L),
      time: 5L,
      point: AsDouble(3.0),
      exemplars: [
        {
          time: 4L,
          value: 3.0,
          attributes: [("route", @trace.Str("/orders"))],
          trace_id: Some(
            b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
          ),
          span_id: Some(b"\x11\x12\x13\x14\x15\x16\x17\x18"),
        },
      ],
      flags: 0,
    }),
  ])
  assert_true(body.contains("\"startTimeUnixNano\":\"1\""))
  assert_true(
    body.contains(
      "\"exemplars\":[{\"filteredAttributes\":[{\"key\":\"route\"," +
      "\"value\":{\"stringValue\":\"/orders\"}}],\"timeUnixNano\":\"4\"," +
      "\"asDouble\":3,\"traceId\":\"0102030405060708090a0b0c0d0e0f10\"," +
      "\"spanId\":\"1112131415161718\"}]",
    ),
  )
}

///|
test "attribute values keep the type they were given" {
  let body = encode_metrics([
    metric_of({
      attributes: [
        ("ok", @trace.Bool(true)),
        ("count", @trace.Int(12L)),
        ("ratio", @trace.Double(0.5)),
        ("tags", @trace.Strs(["a", "b"])),
      ],
      start: None,
      time: 5L,
      point: AsDouble(1.0),
      exemplars: [],
      flags: 0,
    }),
  ])
  assert_true(body.contains("{\"key\":\"ok\",\"value\":{\"boolValue\":true}}"))
  assert_true(
    body.contains("{\"key\":\"count\",\"value\":{\"intValue\":\"12\"}}"),
  )
  assert_true(
    body.contains("{\"key\":\"ratio\",\"value\":{\"doubleValue\":0.5}}"),
  )
  assert_true(
    body.contains(
      "{\"key\":\"tags\",\"value\":{\"arrayValue\":{\"values\":[" +
      "{\"stringValue\":\"a\"},{\"stringValue\":\"b\"}]}}}",
    ),
  )
}

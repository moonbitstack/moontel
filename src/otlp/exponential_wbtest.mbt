// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn exponential_metric() -> Metric {
  {
    name: "request.duration",
    description: "How long a request took.",
    unit: "s",
    kind: ExponentialHistogram(temporality=Cumulative),
    points: [
      {
        attributes: [("route", @trace.Str("/orders"))],
        start: Some(1L),
        time: 5L,
        point: ExponentialBuckets(
          scale=2,
          zero_count=1L,
          positive_offset=-1,
          positive_counts=[2L, 1L],
          negative_offset=0,
          negative_counts=[],
          sum=3.5,
          count=4L,
          min=Some(0.0),
          max=Some(2.0),
        ),
        exemplars: [],
        flags: 0,
      },
    ],
  }
}

///|
test "an exponential histogram is a field of its own in the JSON body" {
  let body = encode_metrics([exponential_metric()])
  assert_true(body.contains("\"exponentialHistogram\""))
  assert_true(body.contains("\"scale\":2"))
  assert_true(body.contains("\"zeroCount\":\"1\""))
  assert_true(
    body.contains("\"positive\":{\"offset\":-1,\"bucketCounts\":[\"2\",\"1\"]}"),
  )
  assert_true(body.contains("\"negative\":{\"offset\":0,\"bucketCounts\":[]}"))
  assert_true(body.contains("\"aggregationTemporality\":2"))
  assert_true(body.contains("\"count\":\"4\""))
  assert_true(body.contains("\"sum\":3.5"))
}

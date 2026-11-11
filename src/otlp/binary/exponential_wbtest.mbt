// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn exponential_metric() -> @otlp.Metric {
  {
    name: "request.duration",
    description: "How long a request took.",
    unit: "s",
    kind: @otlp.ExponentialHistogram(temporality=@otlp.Cumulative),
    points: [
      {
        attributes: [("route", @trace.Str("/orders"))],
        start: Some(1L),
        time: 5L,
        point: @otlp.ExponentialBuckets(
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
test "an exponential point keeps its scale, its sides and its counts in protobuf" {
  let body = encode_metrics([exponential_metric()])
  let request = decode_fields(body[:])
  let resource_metrics = decode_fields(required(request, 1).bytes)
  let scope_metrics = decode_fields(required(resource_metrics, 2).bytes)
  let encoded = decode_fields(required(scope_metrics, 2).bytes)
  assert_eq(required(encoded, 1).bytes.to_owned(), b"request.duration")
  // The data oneof's exponential_histogram is field 10.
  let histogram = decode_fields(required(encoded, 10).bytes)
  assert_eq(required(histogram, 2).varint, 2UL)
  let point = decode_fields(required(histogram, 1).bytes)
  assert_eq(required(point, 2).varint, 1UL)
  assert_eq(required(point, 3).varint, 5UL)
  assert_eq(required(point, 4).varint, 4UL)
  assert_eq(required(point, 5).varint, (3.5 : Double).reinterpret_as_uint64())
  // `scale` is a sint32, so its wire form is the zigzag of the value: 2 travels as 4.
  assert_eq(required(point, 6).varint, 4UL)
  assert_eq(required(point, 7).varint, 1UL)
  let positive = decode_fields(required(point, 8).bytes)
  // `offset` is a sint32 as well: -1 travels as the zigzag 1.
  assert_eq(required(positive, 1).varint, 1UL)
  // `bucket_counts` is a packed repeated field: two varints in one length-delimited
  // field, 2 and then 1.
  assert_eq(required(positive, 2).bytes.to_owned(), b"\x02\x01")
}

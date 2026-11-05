// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Ids a test can read: sixteen octets counting up, and eight starting at `first`.
fn trace_id() -> Bytes {
  b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10"
}

///|
fn span_id(first : Int32) -> Bytes {
  let bytes : Array[Byte] = []
  for i in 0..<8 {
    bytes.push((first + i).to_byte())
  }
  Bytes::from_array(bytes)
}

///|
/// A span whose every field is set, so the encoding of each one is visible.
fn full_span() -> @trace.SpanData {
  {
    context: @trace.TraceContext::new(
      trace_id=trace_id(),
      span_id=span_id(0x11),
      flags=@trace.sampled_flag,
    ),
    parent: Some(span_id(0x21)),
    name: "GET /orders",
    kind: @trace.Server,
    start: 1000L,
    end: 2500L,
    attributes: [("http.response.status_code", @trace.Int(200L))],
    events: [
      {
        name: "exception",
        at: 1500L,
        attributes: [("exception.message", @trace.Str("boom"))],
      },
    ],
    links: [
      {
        context: @trace.TraceContext::new(
          trace_id=b"\xaa\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
          span_id=span_id(0x31),
        ),
        attributes: [("rel", @trace.Str("batch"))],
      },
    ],
    status: @trace.Error("boom"),
    dropped: { attributes: 1, events: 0, links: 0, },
  }
}

///|
test "a span is written as the OTLP schema names its fields" {
  let body = encode_traces([full_span()])
  let expected = "{\"resourceSpans\":[" +
    "{\"resource\":{\"attributes\":[{\"key\":\"service.name\"," +
    "\"value\":{\"stringValue\":\"unknown_service\"}}]}," +
    "\"scopeSpans\":[{\"scope\":{\"name\":\"moonbitstack/moontel\"},\"spans\":[{" +
    "\"traceId\":\"0102030405060708090a0b0c0d0e0f10\"," +
    "\"spanId\":\"1112131415161718\"," +
    "\"parentSpanId\":\"2122232425262728\"," +
    "\"name\":\"GET /orders\",\"kind\":2," +
    "\"startTimeUnixNano\":\"1000\",\"endTimeUnixNano\":\"2500\"," +
    "\"attributes\":[{\"key\":\"http.response.status_code\"," +
    "\"value\":{\"intValue\":\"200\"}}]," +
    "\"events\":[{\"timeUnixNano\":\"1500\",\"name\":\"exception\"," +
    "\"attributes\":[{\"key\":\"exception.message\"," +
    "\"value\":{\"stringValue\":\"boom\"}}]}]," +
    "\"links\":[{\"traceId\":\"aa02030405060708090a0b0c0d0e0f10\"," +
    "\"spanId\":\"3132333435363738\",\"attributes\":[{\"key\":\"rel\"," +
    "\"value\":{\"stringValue\":\"batch\"}}]}]," +
    "\"status\":{\"code\":2,\"message\":\"boom\"}," +
    "\"droppedAttributesCount\":1,\"flags\":1}]}]}]}"
  assert_eq(body, expected)
}

///|
test "a root span has no parent and no status when there is nothing to say" {
  let span = {
    ..full_span(),
    parent: None,
    events: [],
    links: [],
    status: @trace.Unset,
    dropped: @trace.dropped_nothing,
    attributes: [],
  }
  let body = encode_traces([span])
  assert_false(body.contains("parentSpanId"))
  assert_false(body.contains("status"))
  assert_false(body.contains("droppedAttributesCount"))
  assert_false(body.contains("events"))
  assert_false(body.contains("links"))
}

///|
test "every span kind is the number OTLP gives it" {
  let kinds : Array[(@trace.SpanKind, String)] = [
    (@trace.Internal, "\"kind\":1,"),
    (@trace.Server, "\"kind\":2,"),
    (@trace.Client, "\"kind\":3,"),
    (@trace.Producer, "\"kind\":4,"),
    (@trace.Consumer, "\"kind\":5,"),
  ]
  for entry in kinds {
    let body = encode_traces([{ ..full_span(), kind: entry.0, }])
    assert_true(body.contains(entry.1))
  }
}

///|
test "an ok status carries a code and no message" {
  let body = encode_traces([{ ..full_span(), status: @trace.Ok, }])
  assert_true(body.contains("\"status\":{\"code\":1}"))
}

///|
test "the resource and the scope travel with the spans" {
  let body = encode_traces(
    [full_span()],
    resource=Resource::of_service("orders").with_attribute(
      "deployment.environment.name",
      @trace.Str("prod"),
    ),
    scope=Scope::new(name="moonbitstack/moontel", version="1.4.0"),
  )
  assert_true(
    body.contains(
      "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"orders\"}}",
    ),
  )
  assert_true(
    body.contains(
      "{\"key\":\"deployment.environment.name\",\"value\":{\"stringValue\":\"prod\"}}",
    ),
  )
  assert_true(
    body.contains(
      "{\"scope\":{\"name\":\"moonbitstack/moontel\",\"version\":\"1.4.0\"}",
    ),
  )
}

///|
test "an empty batch is still a well-formed request" {
  let body = encode_traces([])
  assert_true(body.has_prefix("{\"resourceSpans\":[{\"resource\":"))
  assert_true(body.contains("\"spans\":[]"))
}

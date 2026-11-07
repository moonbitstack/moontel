// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One field of an encoded message, as the wire spells it: the number, the wire
/// type, and whatever the payload turned out to be.
///
/// The decoder below is in the test file rather than in the library on purpose. It
/// is the other half of the encoder — a reader that knows nothing but the wire
/// format — and keeping it here means a bug has to be made twice, in two places
/// written to disagree, before these tests pass.
struct WireField {
  number : Int32
  varint : UInt64
  bytes : BytesView
}

///|
fn decode_fields(body : BytesView) -> Array[WireField] {
  let out : Array[WireField] = []
  let mut at = 0
  while at < body.length() {
    let (tag, after_tag) = take_varint(body, at)
    at = after_tag
    let number = (tag >> 3).to_int()
    let wire = (tag & 7UL).to_int()
    if wire == 0 {
      let (value, after) = take_varint(body, at)
      out.push({ number, varint: value, bytes: body[0:0], })
      at = after
    } else if wire == 1 {
      out.push({
        number,
        varint: little_endian(body, at, 8),
        bytes: body[at:at + 8],
      })
      at = at + 8
    } else if wire == 5 {
      out.push({
        number,
        varint: little_endian(body, at, 4),
        bytes: body[at:at + 4],
      })
      at = at + 4
    } else {
      let (length, after) = take_varint(body, at)
      let end = after + length.to_int()
      out.push({ number, varint: 0UL, bytes: body[after:end], })
      at = end
    }
  }
  out
}

///|
/// The field numbered `number`, or `None` when the message does not carry it.
fn field(fields : Array[WireField], number : Int32) -> WireField? {
  for candidate in fields {
    if candidate.number == number {
      return Some(candidate)
    }
  }
  None
}

///|
/// A field the message must carry, so a test can say what it expects instead of
/// unwrapping everywhere.
fn required(fields : Array[WireField], number : Int32) -> WireField raise {
  match field(fields, number) {
    Some(found) => found
    None => fail("no field \{number} in \{fields.length()} fields")
  }
}

///|
fn take_varint(body : BytesView, start : Int32) -> (UInt64, Int32) {
  let mut value = 0UL
  let mut shift = 0
  let mut at = start
  while at < body.length() {
    let byte = body[at].to_int().to_uint64()
    at = at + 1
    value = value | ((byte & 0x7FUL) << shift)
    if byte < 0x80UL {
      break
    }
    shift = shift + 7
  }
  (value, at)
}

///|
fn little_endian(body : BytesView, start : Int32, width : Int32) -> UInt64 {
  let mut value = 0UL
  let mut shift = 0
  for index in 0..<width {
    value = value | (body[start + index].to_int().to_uint64() << shift)
    shift = shift + 8
  }
  value
}

///|
/// A span with every field these encoders write, so one test can look at all of
/// them.
fn proto_span() -> @trace.SpanData {
  {
    context: @trace.TraceContext::new(
      trace_id=b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
      span_id=b"\x11\x12\x13\x14\x15\x16\x17\x18",
      flags=@trace.sampled_flag,
    ),
    parent: Some(b"\x21\x22\x23\x24\x25\x26\x27\x28"),
    name: "GET /orders",
    kind: @trace.Server,
    start: 10L,
    end: 20L,
    attributes: [
      ("http.request.method", @trace.Str("GET")),
      ("retry", @trace.Int(2L)),
    ],
    events: [
      { name: "cache.miss", at: 12L, attributes: [("size", @trace.Int(3L))], },
    ],
    links: [],
    status: @trace.Error("upstream said no"),
    dropped: @trace.dropped_nothing,
  }
}

///|
test "a protobuf trace request nests a span under a resource and a scope" {
  let body = encode_traces(
    [proto_span()],
    resource=@otlp.Resource::new(attributes=[
      ("service.name", @trace.Str("orders")),
    ]),
    scope=@otlp.Scope::{ name: "orders", version: None, attributes: [], },
  )
  let request = decode_fields(body[:])
  let resource_spans = decode_fields(required(request, 1).bytes)
  // The resource is a message of its own, and it carries service.name.
  let resource = decode_fields(required(resource_spans, 1).bytes)
  let service = decode_fields(required(resource, 1).bytes)
  assert_eq(required(service, 1).bytes.to_owned(), b"service.name")
  let scope_spans = decode_fields(required(resource_spans, 2).bytes)
  let scope = decode_fields(required(scope_spans, 1).bytes)
  assert_eq(required(scope, 1).bytes.to_owned(), b"orders")
  let span = decode_fields(required(scope_spans, 2).bytes)
  assert_eq(
    required(span, 1).bytes.to_owned(),
    b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
  )
  assert_eq(
    required(span, 2).bytes.to_owned(),
    b"\x11\x12\x13\x14\x15\x16\x17\x18",
  )
  assert_eq(
    required(span, 4).bytes.to_owned(),
    b"\x21\x22\x23\x24\x25\x26\x27\x28",
  )
  assert_eq(required(span, 5).bytes.to_owned(), b"GET /orders")
  // SPAN_KIND_SERVER is 2, and an enum travels as its number.
  assert_eq(required(span, 6).varint, 2UL)
  assert_eq(required(span, 7).varint, 10UL)
  assert_eq(required(span, 8).varint, 20UL)
  // The status is a message: code 2 for an error, and the message beside it.
  let status = decode_fields(required(span, 15).bytes)
  assert_eq(required(status, 3).varint, 2UL)
  assert_eq(required(status, 2).bytes.to_owned(), b"upstream said no")
  let event = decode_fields(required(span, 11).bytes)
  assert_eq(required(event, 1).varint, 12UL)
  assert_eq(required(event, 2).bytes.to_owned(), b"cache.miss")
}

///|
test "a protobuf log record keeps its severity, its ids and its times" {
  let context = @trace.TraceContext::new(
    trace_id=b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
    span_id=b"\x11\x12\x13\x14\x15\x16\x17\x18",
    flags=@trace.sampled_flag,
  )
  let record = @log.LogRecord::new(
    severity=@log.Severity::Warn,
    body=@trace.Str("payment retried"),
    at=30L,
    observed=31L,
    scope="orders",
  )
  let body = encode_logs([record.with_context(context)])
  let request = decode_fields(body[:])
  let resource_logs = decode_fields(required(request, 1).bytes)
  let scope_logs = decode_fields(required(resource_logs, 2).bytes)
  let log_record = decode_fields(required(scope_logs, 2).bytes)
  assert_eq(required(log_record, 1).varint, 30UL)
  // SEVERITY_NUMBER_WARN is 13.
  assert_eq(required(log_record, 2).varint, 13UL)
  assert_eq(required(log_record, 3).bytes.to_owned(), b"WARN")
  let value = decode_fields(required(log_record, 5).bytes)
  assert_eq(required(value, 1).bytes.to_owned(), b"payment retried")
  assert_eq(
    required(log_record, 9).bytes.to_owned(),
    b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
  )
  assert_eq(required(log_record, 11).varint, 31UL)
}

///|
test "a protobuf metric keeps its name, its temporality and its point" {
  let metric : @otlp.Metric = {
    name: "orders_placed",
    description: "Orders placed.",
    unit: "{order}",
    kind: Sum(temporality=Cumulative, monotonic=true),
    points: [
      {
        attributes: [("region", @trace.Str("eu"))],
        start: Some(1L),
        time: 5L,
        point: AsDouble(3.5),
        exemplars: [],
        flags: 0,
      },
    ],
  }
  let body = encode_metrics([metric])
  let request = decode_fields(body[:])
  let resource_metrics = decode_fields(required(request, 1).bytes)
  let scope_metrics = decode_fields(required(resource_metrics, 2).bytes)
  let encoded = decode_fields(required(scope_metrics, 2).bytes)
  assert_eq(required(encoded, 1).bytes.to_owned(), b"orders_placed")
  assert_eq(required(encoded, 2).bytes.to_owned(), b"Orders placed.")
  assert_eq(required(encoded, 3).bytes.to_owned(), b"{order}")
  let sum = decode_fields(required(encoded, 7).bytes)
  let point = decode_fields(required(sum, 1).bytes)
  // AGGREGATION_TEMPORALITY_CUMULATIVE is 2, and a monotonic sum says so.
  assert_eq(required(sum, 2).varint, 2UL)
  assert_eq(required(sum, 3).varint, 1UL)
  assert_eq(required(point, 2).varint, 1UL)
  assert_eq(required(point, 3).varint, 5UL)
  assert_eq(required(point, 4).varint, (3.5 : Double).reinterpret_as_uint64())
}

///|
/// A member of a JSON object, or a failure naming what was missing: a test that has
/// to unwrap four levels should say which level was empty.
fn field_of(value : @corejson.Json, name : String) -> @corejson.Json raise {
  match value {
    @corejson.Object(fields) =>
      match fields.get(name) {
        Some(found) => found
        None => fail("no \{name} in the JSON body")
      }
    _ => fail("\{name} is read off an object")
  }
}

///|
fn elements(value : @corejson.Json) -> Array[@corejson.Json] raise {
  match value {
    @corejson.Array(items) => items
    _ => fail("a repeated field is an array in the JSON body")
  }
}

///|
fn text_of(value : @corejson.Json) -> String raise {
  match value {
    @corejson.String(text) => text
    _ => fail("expected text in the JSON body")
  }
}

///|
fn number_of(value : @corejson.Json) -> Double raise {
  match value {
    @corejson.Number(number, ..) => number
    _ => fail("expected a number in the JSON body")
  }
}

///|
/// The two encodings of one span carry the same thing: the JSON body read as JSON,
/// the binary body read as fields, and the values compared.
test "the two encodings agree about one span" {
  let spans = [proto_span()]
  let resource = @otlp.Resource::new(attributes=[
    ("service.name", @trace.Str("orders")),
  ])
  let scope = @otlp.Scope::{ name: "orders", version: None, attributes: [], }
  let text = @utf8.decode_lossy(@otlp.json.traces(spans, resource, scope))
  let binary = encode_traces(spans, resource~, scope~)
  let decoded = @corejson.parse(text[:]) catch {
    refused => fail("the JSON body is not JSON: \{refused.to_string()}")
  }
  let resources = elements(field_of(decoded, "resourceSpans"))
  let scopes = elements(field_of(resources[0], "scopeSpans"))
  let json_span = elements(field_of(scopes[0], "spans"))[0]
  let request = decode_fields(binary[:])
  let resource_spans = decode_fields(required(request, 1).bytes)
  let scope_spans = decode_fields(required(resource_spans, 2).bytes)
  let span = decode_fields(required(scope_spans, 2).bytes)
  assert_eq(text_of(field_of(json_span, "name")), "GET /orders")
  assert_eq(required(span, 5).bytes.to_owned(), b"GET /orders")
  assert_eq(number_of(field_of(json_span, "kind")), 2.0)
  assert_eq(required(span, 6).varint, 2UL)
  assert_eq(
    text_of(field_of(json_span, "traceId")),
    "0102030405060708090a0b0c0d0e0f10",
  )
  assert_eq(
    required(span, 1).bytes.to_owned(),
    b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
  )
  // The status is a message in one body and an object in the other, and both say
  // the same thing about the span.
  let status = field_of(json_span, "status")
  assert_eq(number_of(field_of(status, "code")), 2.0)
  let binary_status = decode_fields(required(span, 15).bytes)
  assert_eq(required(binary_status, 3).varint, 2UL)
  assert_eq(text_of(field_of(status, "message")), "upstream said no")
  assert_eq(required(binary_status, 2).bytes.to_owned(), b"upstream said no")
}

///|
/// A reply's count of refused records, in both encodings: the request was accepted
/// and some of it was not, which is what a report has to be able to say.
test "the refused count is read out of a reply in either encoding" {
  let json_reply = @otlp.Reply::{
    status: 200,
    headers: [],
    body: @utf8.encode(
      "{\"partialSuccess\":{\"rejectedSpans\":\"2\",\"errorMessage\":\"too many\"}}",
    ),
  }
  assert_eq(@otlp.json.rejected(json_reply.body), Some(2))
  let response = ExportTraceServiceResponse::new()
  let success = ExportTracePartialSuccess::new()
  success.rejected_spans = Some(2L)
  response.partial_success = Some(success)
  let binary_reply = encoded(response)
  assert_eq(protobuf.rejected(binary_reply), Some(2))
}

///|
/// A reply that says nothing about what it refused is not a reply that refused
/// nothing, and neither is a body that cannot be read at all.
test "a reply with no count answers nothing" {
  let empty = ExportTraceServiceResponse::new()
  assert_eq(protobuf.rejected(encoded(empty)), None)
  assert_eq(protobuf.rejected(b"not a protobuf body"), None)
  let accepted = @otlp.Reply::{
    status: 200,
    headers: [],
    body: @utf8.encode("{}"),
  }
  assert_eq(@otlp.json.rejected(accepted.body), None)
}

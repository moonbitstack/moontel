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
  let body = encode_traces_protobuf(
    [proto_span()],
    resource=Resource::new(attributes=[("service.name", @trace.Str("orders"))]),
    scope={ name: "orders", version: None, attributes: [], },
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
  let body = encode_logs_protobuf([record.with_context(context)])
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
  let metric : Metric = {
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
  let body = encode_metrics_protobuf([metric])
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

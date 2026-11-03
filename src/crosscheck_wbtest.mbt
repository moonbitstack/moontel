// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// One scenario, two implementations. The ids, the timestamps, the attributes, the
// events and the headers here are the ones in
// `scripts/trace_crosscheck_expected.json`, which is what the OpenTelemetry Python
// SDK produced for the same sequence. The record is checked in and replayed, so the
// library is held to another implementation's output rather than to its own idea of
// it.

///|
/// A source of randomness that hands out `values` in order.
fn scripted_rand(values : Array[Bytes]) -> (Int32) -> Bytes {
  let next = Ref(0)
  width => {
    let index = next.val
    next.val = next.val + 1
    if index < values.length() {
      values[index]
    } else {
      Bytes::make(width, b'\xff')
    }
  }
}

///|
/// A field of a JSON object.
fn field(json : Json, name : String) -> Json raise {
  match json {
    Object(fields) =>
      match fields.get(name) {
        Some(value) => value
        None => fail("the record has no field \{name}")
      }
    _ => fail("expected an object at \{name}")
  }
}

///|
/// A JSON value that has to be a string.
fn as_text(json : Json) -> String raise {
  match json {
    String(text) => text
    _ => fail("expected a string, got " + json.stringify())
  }
}

///|
/// A JSON number as decimal text, for the one field in the record that is a number
/// rather than a string: the sampling ratio.
fn as_number(json : Json) -> String raise {
  match json {
    Number(value, ..) => value.to_string()
    _ => fail("expected a number, got " + json.stringify())
  }
}

///|
/// The array a JSON value has to be.
fn as_array(json : Json) -> Array[Json] raise {
  match json {
    Array(items) => items
    _ => fail("expected an array, got " + json.stringify())
  }
}

///|
/// Whether our attribute value is the one the record holds, type and all.
fn same_value(value : @trace.Value, json : Json) -> Bool raise {
  let kind = as_text(field(json, "type"))
  let payload = field(json, "value")
  match (kind, value) {
    ("bool", @trace.Bool(ours)) =>
      (payload is True && ours) || (payload is False && !ours)
    ("int", @trace.Int(ours)) => as_text(payload) == ours.to_string()
    ("double", @trace.Double(ours)) => as_number(payload) == ours.to_string()
    ("string", @trace.Str(ours)) => as_text(payload) == ours
    ("strings", @trace.Strs(ours)) => as_array(payload).map(as_text) == ours
    ("ints", @trace.Ints(ours)) =>
      as_array(payload).map(as_text) == ours.map(v => v.to_string())
    ("doubles", @trace.Doubles(ours)) =>
      as_array(payload).map(as_number) == ours.map(v => v.to_string())
    ("bools", @trace.Bools(ours)) =>
      as_array(payload).map(v => v is True) == ours
    _ => fail("the record has \{kind} where this span has a different type")
  }
}

///|
/// Whether our attribute list is the record's, in the same order.
fn same_attributes(
  ours : Array[(String, @trace.Value)],
  json : Json,
) -> Bool raise {
  let their = as_array(json)
  if ours.length() != their.length() {
    fail(
      "attribute count: this span has \{ours.length()}, the record \{their.length()}",
    )
  }
  for i, attribute in ours {
    let pair = as_array(their[i])
    if as_text(pair[0]) != attribute.0 {
      fail(
        "attribute \{i}: this span has \{attribute.0}, the record \{as_text(pair[0])}",
      )
    }
    if !same_value(attribute.1, pair[1]) {
      fail("attribute \{attribute.0} differs from the record")
    }
  }
  true
}

///|
/// Whether one of our spans is the record's, field by field.
fn same_span(ours : @trace.SpanData, json : Json) -> Bool raise {
  let name = as_text(field(json, "name"))
  if ours.name != name {
    fail("span name: this run has \{ours.name}, the record \{name}")
  }
  let our_kind = match ours.kind {
    Internal => "Internal"
    Server => "Server"
    Client => "Client"
    Producer => "Producer"
    Consumer => "Consumer"
  }
  let kind = as_text(field(json, "kind"))
  if our_kind != kind {
    fail("span kind: this run has \{our_kind}, the record \{kind}")
  }
  let trace_id = as_text(field(json, "trace_id"))
  if @base16.encode(ours.context.trace_id[:]) != trace_id {
    fail("trace id differs from the record")
  }
  let span_id = as_text(field(json, "span_id"))
  if @base16.encode(ours.context.span_id[:]) != span_id {
    fail("span id differs from the record")
  }
  let our_parent = match ours.parent {
    Some(id) => Some(@base16.encode(id[:]))
    None => None
  }
  let their_parent = match field(json, "parent_span_id") {
    Null => None
    other => Some(as_text(other))
  }
  if our_parent != their_parent {
    fail("parent span id differs from the record")
  }
  // The record writes 64-bit integers as decimal strings: a nanosecond timestamp
  // is above 2^53, where a JSON number no longer round-trips through a double.
  let start = as_text(field(json, "start"))
  if ours.start.to_string() != start {
    fail("start: this run has \{ours.start}, the record \{start}")
  }
  let end = as_text(field(json, "end"))
  if ours.end.to_string() != end {
    fail("end: this run has \{ours.end}, the record \{end}")
  }
  same_attributes(ours.attributes, field(json, "attributes")) |> ignore
  let their_events = as_array(field(json, "events"))
  if ours.events.length() != their_events.length() {
    fail("event count differs from the record")
  }
  for i, event in ours.events {
    let entry = their_events[i]
    if event.name != as_text(field(entry, "name")) {
      fail("event name differs from the record")
    }
    if event.at.to_string() != as_text(field(entry, "at")) {
      fail("event time differs from the record")
    }
    same_attributes(event.attributes, field(entry, "attributes")) |> ignore
  }
  let status = field(json, "status")
  let code = as_text(field(status, "code"))
  match (ours.status, code) {
    (Unset, "Unset") | (Ok, "Ok") => ()
    (Error(message), "Error") => {
      let description = as_text(field(status, "description"))
      if message != description {
        fail("status description differs from the record")
      }
    }
    _ => fail("status code differs from the record")
  }
  true
}

///|
test "the recorded reference run replays span for span" {
  let record = @json.parse(expected_json) catch {
    error => fail("the record is not valid JSON: \{error}")
  }
  let their_spans = as_array(field(record, "spans"))
  let child_json = their_spans[0]
  let root_json = their_spans[1]

  // The ids come out of the record, so the same trace is replayed rather than one
  // that merely looks like it.
  let trace_id = @base16.decode(as_text(field(root_json, "trace_id"))) catch {
    _ => fail("the record's trace id is not hexadecimal")
  }
  let root_id = @base16.decode(as_text(field(root_json, "span_id"))) catch {
    _ => fail("the record's span id is not hexadecimal")
  }
  let child_id = @base16.decode(as_text(field(child_json, "span_id"))) catch {
    _ => fail("the record's span id is not hexadecimal")
  }
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=scripted_rand([trace_id, root_id, child_id]),
    sink=recorder,
    sampler=@trace.always,
  )

  // The sequence is the one the dump script runs: a root span with five
  // attributes, an event, a child that ends first, then the root's own additions.
  let root = tracer.start(
    "checkout",
    kind=@trace.Server,
    at=1700000000000000000L,
    attributes=[
      ("order.id", @trace.Str("A-1024")),
      ("order.total", @trace.Double(42.5)),
      ("order.items", @trace.Int(3L)),
      ("order.paid", @trace.Bool(true)),
      ("order.tags", @trace.Strs(["new", "gift"])),
    ],
  )
  root.add_event(
    "cache.miss",
    attributes=[("key", @trace.Str("cart:A-1024"))],
    at=1700000000100000000L,
  )
  let child = tracer.start(
    "validate",
    parent=root.context(),
    kind=@trace.Internal,
    at=1700000000200000000L,
    attributes=[("valid", @trace.Bool(true))],
  )
  child.set_status(@trace.Ok)
  child.finish(at=1700000000300000000L)
  root.set_attribute("http.response.status_code", @trace.Int(200L))
  root.set_status(@trace.Error("card declined"))
  root.finish(at=1700000000900000000L)

  let ours = recorder.spans()
  if ours.length() != their_spans.length() {
    fail("span count differs from the record")
  }
  same_span(ours[0], child_json) |> ignore
  same_span(ours[1], root_json) |> ignore
}

///|
test "the recorded reference run replays header for header" {
  let record = @json.parse(expected_json) catch {
    error => fail("the record is not valid JSON: \{error}")
  }
  let headers = field(record, "headers")
  let context = @propagate.parse_traceparent(
    as_text(field(headers, "traceparent"))[:],
  )
  let bag = @propagate.Baggage::parse(as_text(field(headers, "baggage"))[:])
  let outgoing = @propagate.inject([], { context: Some(context), baggage: bag, })
  // The two implementations must agree on the header value, not merely on what it
  // means: byte equality is what a proxy in the middle sees.
  assert_eq(outgoing.length(), 2)
  assert_eq(
    outgoing[0],
    ("traceparent", as_text(field(headers, "traceparent"))),
  )
  assert_eq(outgoing[1], ("baggage", as_text(field(headers, "baggage"))))
}

///|
test "the recorded ratio decisions replay" {
  let record = @json.parse(expected_json) catch {
    error => fail("the record is not valid JSON: \{error}")
  }
  let decisions = as_array(field(record, "ratio"))
  assert_eq(decisions.length(), 27)
  for entry in decisions {
    let trace_id = @base16.decode(as_text(field(entry, "trace_id"))) catch {
      _ => fail("the recorded trace id is not hexadecimal")
    }
    let ratio = match as_number(field(entry, "ratio")) {
      "0.25" => 0.25
      "0.5" => 0.5
      "0.75" => 0.75
      _ => fail("the record holds a ratio this replay does not cover")
    }
    let sampled = @trace.ratio(ratio~).should_sample({
        parent: None,
        trace_id,
        name: "op",
        kind: @trace.Internal,
      }) ==
      @trace.RecordAndSample
    if sampled != (field(entry, "sampled") is True) {
      fail(
        "ratio \{as_number(field(entry, "ratio"))} on \{as_text(field(entry, "trace_id"))}: this library and the reference disagree",
      )
    }
  }
}

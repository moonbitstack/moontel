// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A tracer that keeps everything it exports, and a root span from it.
fn traced(
  sampler~ : &@trace.Sampler = @trace.always,
) -> (@trace.Recorder, @trace.Span) raise {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(rand=counting_rand(), sink=recorder, sampler~)
  (recorder, tracer.start("op", at=1000L))
}

///|
test "an attribute is overwritten in place and keeps its first position" {
  let (_, span) = traced()
  span.set_attribute("a", @trace.Str("1"))
  span.set_attribute("b", @trace.Str("2"))
  span.set_attribute("a", @trace.Str("3"))
  assert_eq(span.attributes(), [("a", @trace.Str("3")), ("b", @trace.Str("2"))])
}

///|
test "attributes past the limit are counted rather than kept" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.always,
    limits=@trace.Limits::new(attributes=2),
  )
  let span = tracer.start("op", at=1L)
  span.set_attributes([
    ("a", @trace.Int(1L)),
    ("b", @trace.Int(2L)),
    ("c", @trace.Int(3L)),
    ("d", @trace.Int(4L)),
  ])
  assert_eq(span.attributes().length(), 2)
  span.finish(at=2L)
  let data = recorder.spans()[0]
  assert_eq(data.attributes, [("a", @trace.Int(1L)), ("b", @trace.Int(2L))])
  assert_eq(data.dropped.attributes, 2)
}

///|
test "a value longer than the limit is cut to it" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.always,
    limits=@trace.Limits::new(attribute_value_length=Some(3)),
  )
  let span = tracer.start("op", at=1L)
  span.set_attributes([
    ("long", @trace.Str("abcdefgh")),
    ("short", @trace.Str("ab")),
    ("list", @trace.Strs(["abcdefgh", "ab"])),
    ("count", @trace.Int(123456789L)),
  ])
  let values = span.attributes()
  assert_eq(values[0].1, @trace.Str("abc"))
  assert_eq(values[1].1, @trace.Str("ab"))
  assert_eq(values[2].1, @trace.Strs(["abc", "ab"]))
  // An integer is not a string: there is nothing to cut.
  assert_eq(values[3].1, @trace.Int(123456789L))
}

///|
test "events keep the order they were added and the time they were given" {
  let (recorder, span) = traced()
  span.add_event("first", at=1010L)
  span.add_event("second", attributes=[("k", @trace.Str("v"))], at=1005L)
  assert_eq(span.events().length(), 2)
  assert_eq(span.events()[0].name, "first")
  assert_eq(span.events()[1].at, 1005L)
  span.finish(at=1020L)
  let data = recorder.spans()[0]
  assert_eq(data.events[1].attributes, [("k", @trace.Str("v"))])
}

///|
test "events past the limit are counted rather than kept" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.always,
    limits=@trace.Limits::new(events=1),
  )
  let span = tracer.start("op", at=1L)
  span.add_event("one", at=2L)
  span.add_event("two", at=3L)
  assert_eq(span.events().length(), 1)
  span.finish(at=4L)
  assert_eq(recorder.spans()[0].dropped.events, 1)
}

///|
test "recording an exception follows the exception conventions" {
  let (recorder, span) = traced()
  span.record_exception(
    message="division by zero",
    at=1005L,
    type_="ArithmeticError",
    attributes=[("exception.message", @trace.Str("override"))],
  )
  span.finish(at=1010L)
  let event = recorder.spans()[0].events[0]
  assert_eq(event.name, "exception")
  assert_eq(event.attributes, [
    ("exception.type", @trace.Str("ArithmeticError")),
    ("exception.message", @trace.Str("override")),
  ])
}

///|
test "status follows Ok above Error above Unset" {
  let (recorder, span) = traced()
  span.set_status(@trace.Error("first"))
  span.set_status(@trace.Ok)
  span.set_status(@trace.Error("too late"))
  assert_eq(span.status(), @trace.Ok)
  span.finish(at=2L)
  assert_eq(recorder.spans()[0].status, @trace.Ok)
}

///|
test "an error replaces an earlier error so the message can improve" {
  let (recorder, span) = traced()
  span.set_status(@trace.Error("first"))
  span.set_status(@trace.Error("second"))
  span.set_status(@trace.Unset)
  span.finish(at=2L)
  assert_eq(recorder.spans()[0].status, @trace.Error("second"))
}

///|
test "a finished span takes no more writes and is exported once" {
  let (recorder, span) = traced()
  span.set_attribute("before", @trace.Int(1L))
  span.finish(at=2000L)
  span.set_attribute("after", @trace.Int(2L))
  span.set_name("renamed")
  span.add_event("late", at=2001L)
  span.set_status(@trace.Error("late"))
  span.finish(at=3000L)
  assert_true(span.is_ended())
  assert_false(span.is_recording())
  assert_eq(recorder.len(), 1)
  let data = recorder.spans()[0]
  assert_eq(data.end, 2000L)
  assert_eq(data.name, "op")
  assert_eq(data.attributes, [("before", @trace.Int(1L))])
  assert_eq(data.events.length(), 0)
  assert_eq(data.status, @trace.Unset)
}

///|
test "a dropped span records nothing and is not exported" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.never,
  )
  let span = tracer.start("op", at=1L)
  assert_false(span.is_recording())
  span.set_attribute("a", @trace.Int(1L))
  span.add_event("e", at=2L)
  span.set_status(@trace.Ok)
  span.finish(at=3L)
  assert_eq(span.attributes().length(), 0)
  assert_eq(recorder.len(), 0)
  // The span still has an identity, so a log line can name it.
  assert_true(span.context().is_valid())
  assert_false(span.context().sampled())
}

///|
test "links are kept, counted past the limit, and may hang off a foreign trace" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.always,
    limits=@trace.Limits::new(links=1),
  )
  let other = @trace.TraceContext::new(
    trace_id=Bytes::make(16, b'\x07'),
    span_id=Bytes::make(8, b'\x09'),
  )
  let span = tracer.start("op", at=1L)
  span.add_link({ context: other, attributes: [("k", @trace.Str("v"))], })
  span.add_link({ context: other, attributes: [], })
  assert_eq(span.links().length(), 1)
  span.finish(at=2L)
  let data = recorder.spans()[0]
  assert_eq(data.links[0].context, other)
  assert_eq(data.dropped.links, 1)
}

///|
test "renaming a span does not move the identity it was given" {
  let (recorder, span) = traced()
  let before = span.context()
  span.set_name("GET /orders")
  assert_eq(span.name(), "GET /orders")
  assert_eq(span.context(), before)
  span.finish(at=2L)
  let data = recorder.spans()[0]
  assert_eq(data.name, "GET /orders")
  assert_eq(data.context, before)
  assert_eq(data.duration(), -998L)
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A tracer whose ids are fixed, so a test knows which span it is writing to.
fn fixed_tracer(recorder : @trace.Recorder) -> @trace.Tracer {
  @trace.Tracer::new(
    rand=width => {
      let bytes : Array[Byte] = []
      for i in 0..<width {
        bytes.push((i + 1).to_byte())
      }
      Bytes::from_array(bytes)
    },
    sink=recorder,
    sampler=@trace.always,
  )
}

///|
test "a named record inside the span becomes one event on it" {
  let tracer = fixed_tracer(@trace.Recorder::new())
  let span = tracer.start("POST /orders", at=100L)
  let events = SpanEvents::new(span~)
  let record = LogRecord::new(
      severity=Severity::Info,
      body=@trace.Str("authorised"),
      at=150L,
    )
    .with_context(span.context())
    .with_event_name("order.authorised")
    .with_attribute("order.id", @trace.Int(7L))
  events.accept(record)
  let recorded = span.events()
  assert_eq(recorded.length(), 1)
  assert_eq(recorded[0].name, "order.authorised")
  assert_eq(recorded[0].at, 150L)
  assert_eq(recorded[0].attributes[0], ("order.id", @trace.Int(7L)))
}

///|
test "a record without a name, or from another span, stays a record" {
  let tracer = fixed_tracer(@trace.Recorder::new())
  let span = tracer.start("POST /orders", at=100L)
  let events = SpanEvents::new(span~)
  events.accept(
    LogRecord::new(severity=Severity::Info, body=@trace.Str("x"), at=1L).with_context(
      span.context(),
    ),
  )
  events.accept(
    LogRecord::new(severity=Severity::Info, body=@trace.Str("x"), at=1L).with_event_name(
      "elsewhere",
    ),
  )
  let other = @trace.TraceContext::new(
    trace_id=b"\xaa\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
    span_id=span.context().span_id,
  )
  events.accept(
    LogRecord::new(severity=Severity::Info, body=@trace.Str("x"), at=1L)
    .with_context(other)
    .with_event_name("elsewhere"),
  )
  assert_eq(span.events().length(), 0)
}

///|
test "a span that has ended takes no more events" {
  let tracer = fixed_tracer(@trace.Recorder::new())
  let span = tracer.start("POST /orders", at=100L)
  let events = SpanEvents::new(span~)
  span.finish(at=200L)
  events.accept(
    LogRecord::new(severity=Severity::Info, body=@trace.Str("late"), at=150L)
    .with_context(span.context())
    .with_event_name("order.close"),
  )
  assert_eq(span.events().length(), 0)
}

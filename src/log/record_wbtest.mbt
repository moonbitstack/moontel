// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "a record is observed at the same moment it happened" {
  let record = LogRecord::new(
    severity=Severity::Info,
    body=@trace.Str("started"),
    at=1000L,
  )
  assert_eq(record.timestamp(), 1000L)
  assert_eq(record.observed, 1000L)
  assert_eq(record.severity, Severity::Info)
  assert_eq(record.dropped, 0)
}

///|
test "a record with no time of its own is ordered by when it was observed" {
  let record = {
    ..LogRecord::new(severity=Severity::Info, body=@trace.Str("late"), at=0L),
    time: None,
    observed: 9000L,
  }
  assert_eq(record.timestamp(), 9000L)
  assert_eq(record.severity_text(), "INFO")
}

///|
test "the text of a severity can be the producer's own" {
  let record = {
    ..LogRecord::new(severity=Severity::Info, body=@trace.Str("x"), at=0L),
    severity_text: Some("NOTICE"),
  }
  assert_eq(record.severity_text(), "NOTICE")
}

///|
test "one attribute replaces the value under the same key and keeps its place" {
  let record = LogRecord::new(
      severity=Severity::Warn,
      body=@trace.Str("x"),
      at=0L,
    )
    .with_attribute("a", @trace.Int(1L))
    .with_attribute("b", @trace.Str("two"))
    .with_attribute("a", @trace.Int(3L))
  assert_eq(record.attributes.length(), 2)
  assert_eq(record.attributes[0].0, "a")
  assert_eq(record.attributes[0].1, @trace.Int(3L))
  assert_eq(record.attributes[1].1, @trace.Str("two"))
}

///|
test "a record inside a span names its trace, its span and its flags" {
  let context = @trace.TraceContext::new(
    trace_id=b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
    span_id=b"\x11\x12\x13\x14\x15\x16\x17\x18",
    flags=@trace.sampled_flag,
  )
  let record = LogRecord::new(
    severity=Severity::Error,
    body=@trace.Str("failed"),
    at=5L,
  ).with_context(context)
  let joined = record.context().unwrap()
  assert_eq(joined.trace_id, context.trace_id)
  assert_eq(joined.span_id, context.span_id)
  assert_true(joined.sampled())
}

///|
test "a record with broken ids belongs to no trace" {
  let zero = LogRecord::new(
    severity=Severity::Info,
    body=@trace.Str("x"),
    at=0L,
  ).with_context(
    @trace.TraceContext::new(
      trace_id=b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
      span_id=b"\x00\x00\x00\x00\x00\x00\x00\x00",
    ),
  )
  assert_true(zero.context() is None)
  let half = {
    ..LogRecord::new(severity=Severity::Info, body=@trace.Str("x"), at=0L),
    trace_id: Some(b"\x01\x02"),
  }
  assert_true(half.context() is None)
}

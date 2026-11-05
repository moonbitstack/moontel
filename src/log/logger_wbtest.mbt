// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Trace and span ids that are not all zero, for a record written inside a span.
fn trace_context(sampled~ : Bool) -> @trace.TraceContext {
  @trace.TraceContext::new(
    trace_id=b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
    span_id=b"\x11\x12\x13\x14\x15\x16\x17\x18",
    flags=if sampled { @trace.sampled_flag } else { b'\x00' },
  )
}

///|
test "a logger writes above its floor and stays quiet below it" {
  let recorder = Recorder::new()
  let logger = Logger::new(sink=recorder, now=() => 10L, floor=Severity::Warn)
  logger.info("ignored")
  assert_false(logger.enabled(Severity::Info))
  logger.warn("kept")
  logger.error("kept too")
  let records = recorder.records()
  assert_eq(records.length(), 2)
  assert_eq(records[0].body, @trace.Str("kept"))
  assert_eq(records[0].severity, Severity::Warn)
}

///|
test "a trace-based logger drops lines written inside a trace nobody sampled" {
  let recorder = Recorder::new()
  let logger = Logger::new(sink=recorder, now=() => 0L, trace_based=true)
  logger.with_context(trace_context(sampled=false)).info("dropped")
  logger.with_context(trace_context(sampled=true)).info("kept")
  logger.info("outside any trace")
  let records = recorder.records()
  assert_eq(records.length(), 2)
  assert_eq(records[0].body, @trace.Str("kept"))
  assert_eq(records[1].body, @trace.Str("outside any trace"))
}

///|
test "the line's own attributes win over the logger's, in the logger's order" {
  let recorder = Recorder::new()
  let logger = Logger::new(sink=recorder, now=() => 0L, attributes=[
    ("service", @trace.Str("orders")),
    ("tier", @trace.Str("web")),
  ])
  logger.info("x", attributes=[
    ("tier", @trace.Str("batch")),
    ("id", @trace.Int(7L)),
  ])
  let record = recorder.records()[0]
  assert_eq(record.attributes.length(), 3)
  assert_eq(record.attributes[0], ("service", @trace.Str("orders")))
  assert_eq(record.attributes[1], ("tier", @trace.Str("batch")))
  assert_eq(record.attributes[2], ("id", @trace.Int(7L)))
}

///|
test "attributes past the limit are counted rather than kept" {
  let recorder = Recorder::new()
  let limits = @trace.Limits::new(attributes=2, attribute_value_length=Some(3))
  let logger = Logger::new(sink=recorder, now=() => 0L, limits~)
  logger.info("x", attributes=[
    ("a", @trace.Str("abcdef")),
    ("b", @trace.Str("b")),
    ("c", @trace.Str("c")),
    ("d", @trace.Str("d")),
  ])
  let record = recorder.records()[0]
  assert_eq(record.attributes.length(), 2)
  assert_eq(record.attributes[0].1, @trace.Str("abc"))
  assert_eq(record.dropped, 2)
}

///|
test "an error becomes an exception attribute, and the caller can overrule it" {
  let recorder = Recorder::new()
  let logger = Logger::new(sink=recorder, now=() => 0L)
  logger.error("could not pay", error=failure())
  logger.error("could not pay", error=failure(), attributes=[
    ("exception.message", @trace.Str("the card was declined")),
  ])
  let records = recorder.records()
  assert_eq(
    records[0].attributes[0],
    ("exception.message", @trace.Str("no funds")),
  )
  assert_eq(
    records[1].attributes[0],
    ("exception.message", @trace.Str("the card was declined")),
  )
}

///|
test "a record written inside a span names that span" {
  let recorder = Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=width => {
      let bytes : Array[Byte] = []
      for i in 0..<width {
        bytes.push((i + 1).to_byte())
      }
      Bytes::from_array(bytes)
    },
    sink=@trace.Recorder::new(),
    sampler=@trace.always,
  )
  let span = tracer.start("GET /orders", at=0L)
  Logger::new(sink=recorder, now=() => 0L).inside(span).info("one order")
  let record = recorder.records()[0]
  assert_eq(record.trace_id, Some(span.context().trace_id))
  assert_eq(record.span_id, Some(span.context().span_id))
  assert_true(record.flags == @trace.sampled_flag)
}

///|
test "the logger names its scope and a nested logger renames it" {
  let recorder = Recorder::new()
  let root = Logger::new(sink=recorder, now=() => 0L, scope="orders")
  root.info("outer")
  root.under("orders/payments").info("inner")
  let records = recorder.records()
  assert_eq(records[0].scope, "orders")
  assert_eq(records[1].scope, "orders/payments")
}

///|
test "a record can name itself and say when it was seen" {
  let recorder = Recorder::new()
  let logger = Logger::new(sink=recorder, now=() => 42L)
  logger.log(
    Severity::Info,
    @trace.Str("placed"),
    at=42L,
    observed=43L,
    event_name="order.placed",
  )
  let record = recorder.records()[0]
  assert_eq(record.event_name, Some("order.placed"))
  assert_eq(record.timestamp(), 42L)
  assert_eq(record.observed, 43L)
}

///|
/// A failure a test hands a logger, to see what becomes of it.
pub(all) suberror Failure {
  Refused(String)
}

///|
/// A failure that has really been raised, which is what a logger is handed.
fn failure() -> Error {
  let caught = try {
    refuse()
    None
  } catch {
    error => Some(error)
  }
  caught.unwrap()
}

///|
fn refuse() -> Unit raise Failure {
  raise Failure::Refused("no funds")
}

///|
pub impl Show for Failure with fn output(self, logger) {
  match self {
    Refused(message) => logger.write_string(message)
  }
}

///|
pub extend Failure with Show::{to_string, output}

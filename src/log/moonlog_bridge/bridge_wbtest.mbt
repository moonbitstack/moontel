// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A `moonlog` entry for a record written by `orders`, with one field of each
/// shape and a caller.
fn entry() -> @moonlog.Entry {
  let record = @moonlog.Record::of(@moonlog.info, "orders", "order placed")
    .set("order.id", @moonlog.Value::of_long(7L))
    .set("amount", @moonlog.Value::of_float(12.5))
    .set("cached", @moonlog.Value::of_bool(false))
    .set("note", @moonlog.Value::of_null())
    .stamped(1000L)
    .located("orders.mbt", line=42)
  { record, line: "INFO order placed", }
}

///|
/// A context with ids a test can recognise.
fn context() -> @trace.TraceContext {
  @trace.TraceContext::new(
    trace_id=b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
    span_id=b"\x11\x12\x13\x14\x15\x16\x17\x18",
    flags=@trace.sampled_flag,
  )
}

///|
test "a logger line arrives with its level, its message and its fields" {
  let recorder = @log.Recorder::new()
  let bridge = Bridge::new(sink=recorder, now=() => 2000L)
  let outcome = bridge.write(entry())
  assert_true(outcome is Ok(_))
  let record = recorder.records()[0]
  assert_eq(record.severity, @log.Severity::Info)
  assert_eq(record.body, @trace.Str("order placed"))
  assert_eq(record.timestamp(), 1000L)
  assert_eq(record.observed, 2000L)
  assert_eq(record.attributes.length(), 6)
  assert_eq(record.attributes[0], ("order.id", @trace.Int(7L)))
  assert_eq(record.attributes[1], ("amount", @trace.Double(12.5)))
  assert_eq(record.attributes[2], ("cached", @trace.Bool(false)))
  assert_eq(record.attributes[3], ("note", @trace.Str("null")))
}

///|
test "the caller becomes the code location the semantic conventions name" {
  let recorder = @log.Recorder::new()
  let bridge = Bridge::new(sink=recorder, now=() => 0L)
  ignore(bridge.write(entry()))
  let record = recorder.records()[0]
  let mut file = ""
  let mut line = 0L
  for attribute in record.attributes {
    if attribute.0 == "code.filepath" {
      match attribute.1 {
        @trace.Str(value) => file = value
        _ => ()
      }
    }
    if attribute.0 == "code.lineno" {
      match attribute.1 {
        @trace.Int(value) => line = value
        _ => ()
      }
    }
  }
  assert_eq(file, "orders.mbt")
  assert_eq(line, 42L)
}

///|
test "a line written inside a span names that span" {
  let recorder = @log.Recorder::new()
  let bridge = Bridge::new(sink=recorder, now=() => 0L, current=context())
  ignore(bridge.write(entry()))
  let record = recorder.records()[0]
  assert_eq(record.trace_id, Some(context().trace_id))
  assert_eq(record.span_id, Some(context().span_id))
  assert_true(record.context().unwrap().sampled())
}

///|
test "a line written outside any span names no trace" {
  let recorder = @log.Recorder::new()
  let bridge = Bridge::new(sink=recorder, now=() => 0L)
  ignore(bridge.write(entry()))
  assert_eq(recorder.records()[0].trace_id, None)
}

///|
test "every level of the logger maps to the severity of the same name" {
  let levels : Array[(@moonlog.Level, @log.Severity)] = [
    (@moonlog.trace, @log.Severity::Trace),
    (@moonlog.debug, @log.Severity::Debug),
    (@moonlog.info, @log.Severity::Info),
    (@moonlog.warn, @log.Severity::Warn),
    (@moonlog.error, @log.Severity::Error),
    (@moonlog.fatal, @log.Severity::Fatal),
  ]
  for entry in levels {
    let recorder = @log.Recorder::new()
    let bridge = Bridge::new(sink=recorder, now=() => 0L)
    ignore(
      bridge.write({
        record: @moonlog.Record::of(entry.0, "orders", "x"),
        line: "",
      }),
    )
    assert_eq(recorder.records()[0].severity, entry.1)
  }
}

///|
test "a line with no time of its own is dated when it was seen" {
  let recorder = @log.Recorder::new()
  let bridge = Bridge::new(sink=recorder, now=() => 500L)
  ignore(
    bridge.write({
      record: @moonlog.Record::of(@moonlog.warn, "orders", "late"),
      line: "",
    }),
  )
  let record = recorder.records()[0]
  assert_eq(record.timestamp(), 500L)
  assert_eq(record.observed, 500L)
}

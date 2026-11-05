// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "a log record is written with the severity, body and trace it names" {
  let record = @log.LogRecord::new(
      severity=@log.Severity::Warn,
      body=@trace.Str("slow query"),
      at=1700000000000000000L,
    )
    .with_context(
      @trace.TraceContext::new(
        trace_id=b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
        span_id=b"\x11\x12\x13\x14\x15\x16\x17\x18",
        flags=@trace.sampled_flag,
      ),
    )
    .with_attribute("db.statement", @trace.Str("SELECT 1"))
    .with_event_name("db.slow")
  let body = encode_logs([record])
  let expected = "{\"resourceLogs\":[" +
    "{\"resource\":{\"attributes\":[{\"key\":\"service.name\"," +
    "\"value\":{\"stringValue\":\"unknown_service\"}}]}," +
    "\"scopeLogs\":[{\"scope\":{\"name\":\"moonbitstack/moontel\"}," +
    "\"logRecords\":[{" +
    "\"timeUnixNano\":\"1700000000000000000\"," +
    "\"observedTimeUnixNano\":\"1700000000000000000\"," +
    "\"severityNumber\":13,\"severityText\":\"WARN\"," +
    "\"body\":{\"stringValue\":\"slow query\"}," +
    "\"attributes\":[{\"key\":\"db.statement\",\"value\":{\"stringValue\":\"SELECT 1\"}}]," +
    "\"traceId\":\"0102030405060708090a0b0c0d0e0f10\"," +
    "\"spanId\":\"1112131415161718\",\"flags\":1," +
    "\"eventName\":\"db.slow\"}]}]}]}"
  assert_eq(body, expected)
}

///|
test "records are grouped by the scope that wrote them" {
  let first = @log.LogRecord::new(
    severity=@log.Severity::Info,
    body=@trace.Str("one"),
    at=1L,
    scope="orders",
  )
  let second = @log.LogRecord::new(
    severity=@log.Severity::Info,
    body=@trace.Str("two"),
    at=2L,
    scope="payments",
  )
  let third = @log.LogRecord::new(
    severity=@log.Severity::Info,
    body=@trace.Str("three"),
    at=3L,
    scope="orders",
  )
  let body = encode_logs([first, second, third])
  // Two scopes, in the order they were first seen, and each record under its own.
  let groups : Array[StringView] = body.split("{\"scope\":{\"name\":").collect()
  assert_eq(groups.length(), 3)
  assert_true(groups[1].contains("\"orders\""))
  assert_true(groups[2].contains("\"payments\""))
  assert_true(groups[1].contains("three"))
}

///|
test "a record with no time of its own carries only the moment it was seen" {
  let record = {
    ..@log.LogRecord::new(
      severity=@log.Severity::Debug,
      body=@trace.Str("x"),
      at=5L,
    ),
    time: None,
    observed: 9L,
  }
  let body = encode_logs([record])
  assert_false(body.contains("\"timeUnixNano\""))
  assert_true(body.contains("\"observedTimeUnixNano\":\"9\""))
  assert_true(body.contains("\"severityNumber\":5,\"severityText\":\"DEBUG\""))
}

///|
test "a record outside any trace names none" {
  let record = @log.LogRecord::new(
    severity=@log.Severity::Error,
    body=@trace.Str("x"),
    at=0L,
  )
  let body = encode_logs([record])
  assert_false(body.contains("traceId"))
  assert_false(body.contains("eventName"))
}

///|
test "every severity is the number the data model gives it" {
  let severities : Array[(@log.Severity, String)] = [
    (@log.Severity::Trace, "\"severityNumber\":1,\"severityText\":\"TRACE\""),
    (@log.Severity::Debug, "\"severityNumber\":5,\"severityText\":\"DEBUG\""),
    (@log.Severity::Info, "\"severityNumber\":9,\"severityText\":\"INFO\""),
    (@log.Severity::Warn, "\"severityNumber\":13,\"severityText\":\"WARN\""),
    (@log.Severity::Error, "\"severityNumber\":17,\"severityText\":\"ERROR\""),
    (@log.Severity::Fatal, "\"severityNumber\":21,\"severityText\":\"FATAL\""),
  ]
  for entry in severities {
    let body = encode_logs([
      @log.LogRecord::new(severity=entry.0, body=@trace.Str("x"), at=0L),
    ])
    assert_true(body.contains(entry.1))
  }
}

///|
test "dropped attributes are counted on the record" {
  let record = {
    ..@log.LogRecord::new(
      severity=@log.Severity::Info,
      body=@trace.Str("x"),
      at=0L,
    ),
    dropped: 3,
  }
  assert_true(encode_logs([record]).contains("\"droppedAttributesCount\":3"))
}

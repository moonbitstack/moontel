// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "an acceptance, four retryable codes, and everything else refused" {
  assert_eq(verdict(200), Accepted)
  assert_eq(verdict(204), Accepted)
  assert_eq(verdict(299), Accepted)
  assert_eq(verdict(429), Retry)
  assert_eq(verdict(502), Retry)
  assert_eq(verdict(503), Retry)
  assert_eq(verdict(504), Retry)
}

///|
test "a bad request is not retried, because it would fail the same way" {
  assert_eq(verdict(400), Rejected)
  assert_eq(verdict(401), Rejected)
  assert_eq(verdict(404), Rejected)
  assert_eq(verdict(413), Rejected)
  assert_eq(verdict(500), Rejected)
  assert_eq(verdict(501), Rejected)
  assert_eq(verdict(505), Rejected)
  assert_eq(verdict(301), Rejected)
}

///|
test "Retry-After in seconds is that many milliseconds" {
  assert_eq(retry_after_milliseconds("30", now=0L), Some(30000L))
  assert_eq(retry_after_milliseconds("0", now=0L), Some(0L))
  assert_eq(retry_after_milliseconds(" 7 ", now=0L), Some(7000L))
}

///|
test "Retry-After as an HTTP date is the wait until that moment" {
  // "Sun, 06 Nov 1994 08:49:37 GMT" is 784111777 seconds after the epoch.
  let at = 784111777000L
  assert_eq(
    retry_after_milliseconds("Sun, 06 Nov 1994 08:49:37 GMT", now=at - 5000L),
    Some(5000L),
  )
  assert_eq(
    retry_after_milliseconds("Sun, 06 Nov 1994 08:49:37 GMT", now=at + 5000L),
    Some(0L),
  )
}

///|
test "a Retry-After this library cannot read is no wait at all, and the caller backs off" {
  assert_eq(retry_after_milliseconds("soon", now=0L), None)
  assert_eq(retry_after_milliseconds("-1", now=0L), None)
  assert_eq(retry_after_milliseconds("1.5", now=0L), None)
  assert_eq(
    retry_after_milliseconds("Sun, 06 Foo 1994 08:49:37 GMT", now=0L),
    None,
  )
  assert_eq(
    retry_after_milliseconds("Sun, 06 Nov 1994 08:49:37 UTC", now=0L),
    None,
  )
}

///|
test "the reply reads its own Retry-After header, whatever its case" {
  let reply : Reply = {
    status: 429,
    headers: [("retry-after", "2")],
    body: b"",
  }
  assert_eq(reply.retry_after(now=0L), Some(2000L))
  let other : Reply = {
    status: 429,
    headers: [("Retry-After", "3")],
    body: b"",
  }
  assert_eq(other.retry_after(now=0L), Some(3000L))
}

///|
test "a partial success names how much the server refused" {
  let reply : Reply = {
    status: 200,
    headers: [],
    body: b"{\"partialSuccess\":{\"rejectedSpans\":\"2\",\"errorMessage\":\"too old\"}}",
  }
  assert_eq(reply.rejected(), Some(2))
  let number : Reply = {
    status: 200,
    headers: [],
    body: b"{\"partialSuccess\":{\"rejectedLogRecords\":3}}",
  }
  assert_eq(number.rejected(), Some(3))
  let none : Reply = { status: 200, headers: [], body: b"{}", }
  assert_eq(none.rejected(), None)
  let garbage : Reply = { status: 200, headers: [], body: b"not json", }
  assert_eq(garbage.rejected(), None)
}

///|
test "the backoff starts at the initial interval and grows by half" {
  // The first retry waits five seconds either way, jittered by a fifth.
  assert_eq(backoff(1, 0x00), 4000L)
  let first = backoff(1, 0xff)
  assert_true(first >= 5999L && first <= 6000L)
  // The second grows by half: 7.5 seconds, jittered to between 6 and 9.
  assert_eq(backoff(2, 0x00), 6000L)
  let second = backoff(2, 0xff)
  assert_true(second >= 8999L && second <= 9000L)
}

///|
test "the backoff never waits longer than its maximum" {
  assert_eq(backoff(20, 0xff), 30000L)
  assert_true(backoff(20, 0x00) <= 30000L)
}

///|
test "a generator that does not return four octets leaves the wait unjittered" {
  let odd = Backoff::new()
  assert_eq(odd.delay(1, _ => b"\x01\x02"), 5000L)
}

///|
/// The wait before `attempt`, with a generator that always returns `byte`.
fn backoff(attempt : Int32, byte : Int32) -> Int64 {
  let fixed = byte.to_byte()
  otlp_backoff.delay(attempt, _ => {
    Bytes::from_array([fixed, fixed, fixed, fixed])
  })
}

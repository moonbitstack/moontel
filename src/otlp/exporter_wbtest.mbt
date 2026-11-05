// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A transport that answers from a script and remembers what it was asked.
///
/// A status of zero stands for a request that got no reply at all.
struct Script {
  replies : Array[Reply]
  at : Ref[Int32]
  requests : Ref[Array[Request]]
}

///|
impl Transport for Script with fn send(self, request) {
  self.requests.val.push(request)
  let index = self.at.val
  if index >= self.replies.length() {
    raise Failed::Unreachable(reason="the script has no reply left")
  }
  self.at.val = index + 1
  let reply = self.replies[index]
  if reply.status == 0 {
    raise Failed::Unreachable(reason="the collector did not answer")
  }
  reply
}

///|
fn scripted(replies : Array[Reply]) -> Script {
  { replies, at: Ref(0), requests: Ref([]), }
}

///|
fn ok() -> Reply {
  { status: 200, headers: [], body: "", }
}

///|
fn status_of(status : Int32) -> Reply {
  { status, headers: [], body: "", }
}

///|
/// A span the sampler kept, with every field the encoder needs.
fn sampled_span() -> @trace.SpanData {
  {
    context: @trace.TraceContext::new(
      trace_id=b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
      span_id=b"\x11\x12\x13\x14\x15\x16\x17\x18",
      flags=@trace.sampled_flag,
    ),
    parent: None,
    name: "GET /orders",
    kind: @trace.Server,
    start: 1L,
    end: 2L,
    attributes: [],
    events: [],
    links: [],
    status: @trace.Unset,
    dropped: @trace.dropped_nothing,
  }
}

///|
/// An exporter over `script`, recording every wait it was asked to make.
fn exporter(
  script : Script,
  pauses : Ref[Array[Int64]],
  attempts~ : Int32 = 3,
  timeout~ : Int64 = 30000L,
  limits~ : BodyLimits = recommended_body_limits,
) -> TraceExporter {
  TraceExporter::new(
    transport=script,
    endpoint="http://collector.test:4318/",
    headers=[("x-api-key", "secret")],
    policy=BatchPolicy::new(timeout~),
    limits~,
    attempts~,
    now=() => 0L,
    rand=_ => b"\x00\x00\x00\x00",
    pause=milliseconds => pauses.val.push(milliseconds),
  )
}

///|
async test "a flush posts the batch to the traces path with the caller's headers" {
  let script = scripted([ok()])
  let pauses = Ref([])
  let traces = exporter(script, pauses)
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.delivered, 1)
  assert_eq(report.attempts, 1)
  let requests = script.requests.val
  assert_eq(requests.length(), 1)
  // A trailing slash on the endpoint does not become a double slash in the path.
  assert_eq(requests[0].url, "http://collector.test:4318/v1/traces")
  assert_true(requests[0].body.contains("\"GET /orders\""))
  let mut content_type = ""
  let mut api_key = ""
  for header in requests[0].headers {
    if header.0 == "Content-Type" {
      content_type = header.1
    }
    if header.0 == "x-api-key" {
      api_key = header.1
    }
  }
  assert_eq(content_type, "application/json")
  assert_eq(api_key, "secret")
  assert_eq(pauses.val.length(), 0)
}

///|
async test "a retryable refusal is retried, and the acceptance is what counts" {
  let script = scripted([status_of(503), status_of(503), ok()])
  let pauses = Ref([])
  let traces = exporter(script, pauses)
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.delivered, 1)
  assert_eq(report.attempts, 3)
  assert_eq(script.requests.val.length(), 3)
  // Two waits, both from the backoff: five seconds, then seven and a half.
  assert_eq(pauses.val.length(), 2)
  assert_eq(pauses.val[0], 4000L)
}

///|
async test "a bad request is not retried" {
  let script = scripted([status_of(400)])
  let traces = exporter(script, Ref([]))
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.attempts, 1)
  assert_eq(report.rejected, 1)
  assert_eq(script.requests.val.length(), 1)
}

///|
async test "Retry-After is honoured as the server wrote it" {
  let script = scripted([
    { status: 429, headers: [("Retry-After", "2")], body: "", },
    ok(),
  ])
  let pauses = Ref([])
  let traces = exporter(script, pauses)
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.delivered, 1)
  assert_eq(report.attempts, 2)
  assert_eq(pauses.val, [2000L])
}

///|
async test "a connection that produced no reply is retried" {
  let script = scripted([status_of(0), ok()])
  let pauses = Ref([])
  let traces = exporter(script, pauses)
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.delivered, 1)
  assert_eq(report.attempts, 2)
  assert_eq(pauses.val.length(), 1)
}

///|
async test "when the attempts run out the batch is dropped and counted" {
  let script = scripted([status_of(503), status_of(503), status_of(503)])
  let traces = exporter(script, Ref([]), attempts=3)
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.attempts, 3)
  assert_eq(report.dropped, 1)
  assert_eq(report.delivered, 0)
  assert_eq(traces.stats().dropped, 1L)
  assert_eq(traces.stats().requests, 1L)
}

///|
async test "a wait that would overrun the export timeout ends the attempts" {
  let script = scripted([
    { status: 429, headers: [("Retry-After", "60")], body: "", },
    ok(),
  ])
  let pauses = Ref([])
  let traces = exporter(script, pauses, timeout=1000L)
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.attempts, 1)
  assert_eq(report.dropped, 1)
  // Nothing was waited for: the wait itself was longer than the budget.
  assert_eq(pauses.val.length(), 0)
}

///|
async test "a partial success counts what the server refused" {
  let script = scripted([
    {
      status: 200,
      headers: [],
      body: "{\"partialSuccess\":{\"rejectedSpans\":\"1\",\"errorMessage\":\"stale\"}}",
    },
  ])
  let traces = exporter(script, Ref([]))
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.attempts, 1)
  assert_eq(report.rejected, 1)
  assert_eq(report.delivered, 0)
}

///|
async test "a span the sampler dropped never reaches the collector" {
  let script = scripted([ok()])
  let traces = exporter(script, Ref([]))
  traces.accept({
    ..sampled_span(),
    context: @trace.TraceContext::new(
      trace_id=b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
      span_id=b"\x11\x12\x13\x14\x15\x16\x17\x18",
    ),
  })
  let report = traces.flush()
  assert_eq(report.delivered, 0)
  assert_eq(script.requests.val.length(), 0)
}

///|
async test "a full queue refuses the newest span and says so" {
  let script = scripted([ok()])
  let traces = TraceExporter::new(
    transport=script,
    policy=BatchPolicy::new(queue_limit=2),
    now=() => 0L,
    rand=_ => b"\x00\x00\x00\x00",
    pause=_ => (),
  )
  for _ in 0..<3 {
    traces.accept(sampled_span())
  }
  assert_eq(traces.waiting(), 2)
  assert_eq(traces.stats().refused, 1L)
  let report = traces.flush()
  assert_eq(report.delivered, 2)
  assert_eq(traces.waiting(), 0)
}

///|
async test "the metrics and logs exporters post to their own paths" {
  let script = scripted([ok(), ok()])
  let metrics = MetricsExporter::new(
    transport=script,
    endpoint="http://collector.test:4318",
    now=() => 0L,
    rand=_ => b"\x00\x00\x00\x00",
    pause=_ => (),
  )
  metrics.record({
    name: "queue.depth",
    description: "",
    unit: "",
    kind: Gauge,
    points: [],
  })
  let report = metrics.flush()
  assert_eq(report.delivered, 1)

  let script2 = scripted([ok()])
  let logs = LogsExporter::new(
    transport=script2,
    endpoint="http://collector.test:4318",
    now=() => 0L,
    rand=_ => b"\x00\x00\x00\x00",
    pause=_ => (),
  )
  logs.accept(
    @log.LogRecord::new(
      severity=@log.Severity::Info,
      body=@trace.Str("hello"),
      at=1L,
    ),
  )
  let logged = logs.flush()
  assert_eq(logged.delivered, 1)
  assert_eq(script.requests.val[0].url, "http://collector.test:4318/v1/metrics")
  assert_eq(script2.requests.val[0].url, "http://collector.test:4318/v1/logs")
}

///|
async test "a body over the outgoing limit is dropped without a request" {
  let script = scripted([ok()])
  let pauses = Ref([])
  // An encoded span is far more than four bytes, so nothing here can be sent.
  let traces = exporter(script, pauses, limits={ request: 4, response: 4096, })
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.attempts, 0)
  assert_eq(report.dropped, 1)
  assert_eq(script.requests.val.length(), 0)
  // A request that was never made is not one the stats may count.
  assert_eq(traces.stats().requests, 0L)
  assert_eq(traces.stats().dropped, 1L)
}

///|
async test "a reply over the incoming limit is not retried" {
  // A 200 that rejects nothing would be an acceptance; read past the limit it is a
  // reply this side cannot trust, and the protocol says not to ask again.
  let script = scripted([
    { status: 200, headers: [], body: "{\"partialSuccess\":{}}", },
    ok(),
  ])
  let pauses = Ref([])
  let traces = exporter(script, pauses, limits={ request: 4096, response: 8, })
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.attempts, 1)
  assert_eq(report.delivered, 0)
  assert_eq(report.dropped, 1)
  assert_eq(script.requests.val.length(), 1)
  assert_eq(pauses.val.length(), 0)
}

///|
async test "a reply exactly at the limit is still read" {
  // The bound is a maximum, not a threshold: a body of exactly the limit is a body
  // this side will parse.
  let script = scripted([{ status: 200, headers: [], body: "{}", }])
  let pauses = Ref([])
  let traces = exporter(script, pauses, limits={ request: 4096, response: 2, })
  traces.accept(sampled_span())
  let report = traces.flush()
  assert_eq(report.delivered, 1)
  assert_eq(report.dropped, 0)
}

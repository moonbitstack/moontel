// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A clock that counts in whole nanoseconds from a fixed origin, so every span in a
/// test has a timeline the test wrote.
fn step_clock() -> () -> Int64 {
  let now = Ref(1000L)
  () => {
    now.val = now.val + 100L
    now.val
  }
}

///|
/// A source of randomness that counts, so each span gets ids of its own.
fn counting_rand() -> (Int32) -> Bytes {
  let calls = Ref(0)
  width => {
    calls.val = calls.val + 1
    let bytes : Array[Byte] = []
    for i in 0..<width {
      bytes.push(((calls.val * 31 + i + 1) % 251 + 1).to_byte())
    }
    Bytes::from_array(bytes)
  }
}

///|
/// A tracer that keeps everything, sampled always.
fn recording_tracer(recorder : @trace.Recorder) -> @trace.Tracer {
  @trace.Tracer::new(rand=counting_rand(), sink=recorder, sampler=@trace.always)
}

///|
/// Run `app` on `scope`, feeding it one empty request and collecting what it sends.
async fn drive(app : @spec.AsgiApp, scope : @spec.Scope) -> Array[@spec.Event] {
  let out : Array[@spec.Event] = []
  let sent = Ref(false)
  let receive : @spec.Receive = async fn() {
    @async.pause()
    if sent.val {
      @spec.HttpDisconnect
    } else {
      sent.val = true
      @spec.HttpRequest(body=b"", more_body=false)
    }
  }
  let send : @spec.Send = async fn(event) {
    @async.pause()
    out.push(event)
  }
  app(scope, receive, send)
  out
}

///|
/// An HTTP scope for `path` under `headers`.
fn http_scope(path : String, headers : Array[(String, String)]) -> @spec.Scope {
  @spec.Http(
    @spec.HttpScope::new(
      http_method="GET",
      path~,
      headers~,
      server=("example.com", Some(8080)),
      client=("192.0.2.1", 5555),
    ),
  )
}

///|
/// An application that answers `status` with a fixed body.
fn answering(status : Int32) -> @spec.AsgiApp {
  async fn(_, receive, send) {
    ignore(receive())
    send(
      @spec.HttpResponseStart(
        status~,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(@spec.HttpResponseBody(body=b"ok", more_body=false))
  }
}

///|
/// The start event of a response, which carries the status and the headers.
fn response_start(
  events : Array[@spec.Event],
) -> (Int32, Array[(String, String)]) raise {
  for event in events {
    if event is @spec.HttpResponseStart(status~, headers~, ..) {
      return (status, headers)
    }
  }
  fail("the application sent no response start")
}

///|
/// The value of `name` in `headers`, if any.
fn header(headers : Array[(String, String)], name : String) -> String? {
  for entry in headers {
    if entry.0.to_lower() == name {
      return Some(entry.1)
    }
  }
  None
}

///|
/// A tracing layer over a recorder, with a counting clock.
fn tracing_layer(recorder : @trace.Recorder) -> Tracing {
  Tracing::new(tracer=recording_tracer(recorder), now=step_clock())
}

///|
async test "a request opens a server span and the response carries its context" {
  let recorder = @trace.Recorder::new()
  let layer = tracing_layer(recorder)
  let app = layer.wrap(answering(200))
  let events = drive(app, http_scope("/orders/42", []))
  let (status, headers) = response_start(events)
  assert_eq(status, 200)

  assert_eq(recorder.len(), 1)
  let span = recorder.spans()[0]
  assert_eq(span.name, "GET /orders/42")
  assert_eq(span.kind, @trace.Server)
  assert_eq(span.parent, None)
  assert_true(span.sampled())

  // The response names the span, so a caller can follow the trace further.
  assert_eq(header(headers, "traceparent"), Some(span.context.to_traceparent()))
  assert_eq(header(headers, "tracestate"), None)
}

///|
async test "the span carries the request as the semantic conventions describe it" {
  let recorder = @trace.Recorder::new()
  let layer = tracing_layer(recorder)
  let app = layer.wrap(answering(200))
  let _ = drive(app, http_scope("/orders/42", []))
  let attributes = recorder.spans()[0].attributes
  assert_eq(attributes, [
    ("http.request.method", @trace.Str("GET")),
    ("url.path", @trace.Str("/orders/42")),
    ("url.scheme", @trace.Str("http")),
    ("network.protocol.version", @trace.Str("1.1")),
    ("server.address", @trace.Str("example.com")),
    ("server.port", @trace.Int(8080L)),
    ("client.address", @trace.Str("192.0.2.1")),
    ("client.port", @trace.Int(5555L)),
    // The response is written before the span ends, so its status is on the span
    // by the time a sink sees it.
    ("http.response.status_code", @trace.Int(200L)),
  ])
}

///|
async test "a request that arrives with a trace joins it" {
  let recorder = @trace.Recorder::new()
  let layer = tracing_layer(recorder)
  let app = layer.wrap(answering(200))
  let events = drive(
    app,
    http_scope("/orders/42", [
      ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
      ("tracestate", "vendor=1"),
    ]),
  )
  let span = recorder.spans()[0]
  // The parent travels as a span id, not as a context: the child needs to say
  // where it hangs and nothing else about the parent.
  assert_eq(
    span.context.to_traceparent()[3:35],
    "4bf92f3577b34da6a3ce929d0e0e4736",
  )
  let parent = @trace.TraceContext::new(
    trace_id=span.context.trace_id,
    span_id=span.parent.unwrap(),
  )
  assert_eq(parent.to_traceparent()[36:52], "00f067aa0ba902b7")
  assert_eq(span.context.state.get("vendor"), Some("1"))
  let (_, headers) = response_start(events)
  assert_eq(header(headers, "tracestate"), Some("vendor=1"))
  assert_eq(header(headers, "traceparent"), Some(span.context.to_traceparent()))
}

///|
async test "the response status is on the span, and a 5xx is an error" {
  let recorder = @trace.Recorder::new()
  let layer = tracing_layer(recorder)
  let _ = drive(layer.wrap(answering(204)), http_scope("/a", []))
  let _ = drive(layer.wrap(answering(404)), http_scope("/b", []))
  let _ = drive(layer.wrap(answering(500)), http_scope("/c", []))
  let spans = recorder.spans()
  assert_eq(spans[0].status, @trace.Unset)
  // A 404 is an answer, not a failure: the semantic conventions leave it unset.
  assert_eq(spans[1].status, @trace.Unset)
  assert_eq(spans[2].status, @trace.Error("HTTP 500"))
  assert_eq(
    spans[2].attributes[8],
    ("http.response.status_code", @trace.Int(500L)),
  )
}

///|
async test "an ignored path is passed through without a span" {
  let recorder = @trace.Recorder::new()
  let layer = Tracing::new(
    tracer=recording_tracer(recorder),
    now=step_clock(),
    ignore=["/healthz"],
  )
  let app = layer.wrap(answering(200))
  let events = drive(app, http_scope("/healthz", []))
  assert_eq(recorder.len(), 0)
  let (_, headers) = response_start(events)
  assert_eq(header(headers, "traceparent"), None)
}

///|
async test "a websocket scope is left to the application" {
  let recorder = @trace.Recorder::new()
  let layer = tracing_layer(recorder)
  let sent = Ref(false)
  let app : @spec.AsgiApp = (_, receive, send) => {
    let event = receive()
    sent.val = true
    ignore(send)
    ignore(event)
  }
  let scope = @spec.WebSocket(@spec.WebSocketScope::new(path="/ws"))
  let connect : @spec.Receive = () => @spec.WebSocketConnect
  let sink : @spec.Send = _ => ()
  layer.wrap(app)(scope, connect, sink)
  assert_true(sent.val)
  assert_eq(recorder.len(), 0)
}

///|
async test "baggage rides along to the response, and can be switched off" {
  let recorder = @trace.Recorder::new()
  let layer = tracing_layer(recorder)
  let events = drive(
    layer.wrap(answering(200)),
    http_scope("/a", [("baggage", "userId=alice")]),
  )
  let (_, headers) = response_start(events)
  assert_eq(header(headers, "baggage"), Some("userId=alice"))

  let carried = @trace.Recorder::new()
  let quiet = Tracing::new(
    tracer=recording_tracer(carried),
    now=step_clock(),
    baggage=false,
  )
  let events = drive(
    quiet.wrap(answering(200)),
    http_scope("/a", [("baggage", "userId=alice")]),
  )
  let (_, headers) = response_start(events)
  assert_eq(header(headers, "baggage"), None)
}

///|
async test "the span is finished once, when the application returns" {
  let recorder = @trace.Recorder::new()
  let layer = tracing_layer(recorder)
  let _ = drive(layer.wrap(answering(200)), http_scope("/a", []))
  assert_eq(recorder.len(), 1)
  let span = recorder.spans()[0]
  // The clock advanced twice: once for the start and once for the finish.
  assert_eq(span.start, 1100L)
  assert_eq(span.end, 1200L)
}

///|
async test "an application that fails is recorded and the failure passed on" {
  let recorder = @trace.Recorder::new()
  let layer = tracing_layer(recorder)
  let app : @spec.AsgiApp = (_, _, _) => raise Failure("boom")
  let failed = try {
    let _ = drive(layer.wrap(app), http_scope("/a", []))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  let span = recorder.spans()[0]
  assert_eq(span.events[0].name, "exception")
  assert_true(
    span.events[0].attributes.any(pair => pair.0 == "exception.message"),
  )
}

///|
async test "the layer stacks with the framework's own middleware" {
  let recorder = @trace.Recorder::new()
  let layer = tracing_layer(recorder)
  let app = @mid.stack([@mid.server_errors, layer], answering(200))
  let events = drive(app, http_scope("/a", []))
  let (status, _) = response_start(events)
  assert_eq(status, 200)
  assert_eq(recorder.len(), 1)
}

///|
async test "a broken source of randomness leaves the request untraced rather than failing" {
  let recorder = @trace.Recorder::new()
  let layer = Tracing::new(
    tracer=@trace.Tracer::new(
      rand=_ => Bytes::make(3, b'\x01'),
      sink=recorder,
      sampler=@trace.always,
    ),
    now=step_clock(),
  )
  let events = drive(layer.wrap(answering(200)), http_scope("/a", []))
  let (status, headers) = response_start(events)
  assert_eq(status, 200)
  assert_eq(header(headers, "traceparent"), None)
  assert_eq(recorder.len(), 0)
}

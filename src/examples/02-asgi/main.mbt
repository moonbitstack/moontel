// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A request through a traced application: the middleware reads the context the
/// request arrived with, opens a server span, and puts the context back on the
/// response.
///
///     moon run src/examples/02-asgi
///
/// The application is driven in process, the way a test would drive it; a real
/// server binds the same `@spec.AsgiApp` to a socket instead.
#coverage.skip
async fn main {
  @async.pause()
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=random_bytes,
    sink=recorder,
    sampler=@trace.parent_based(root=@trace.always),
  )
  let layer = @asgi.Tracing::new(tracer~, now=clock())
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    ignore(receive())
    send(
      @spec.HttpResponseStart(
        status=200,
        headers=[("content-type", "application/json")],
        trailers=false,
      ),
    )
    send(@spec.HttpResponseBody(body=b"{\"ok\":true}", more_body=false))
  }
  let traced = layer.wrap(app)

  let scope = @spec.Http(
    @spec.HttpScope::new(
      http_method="POST",
      path="/orders",
      headers=[
        (
          "traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        ),
        ("baggage", "userId=alice"),
      ],
      server=("shop.example.com", Some(8443)),
    ),
  )

  // A minimal server: one request in, whatever the application sends out.
  let handled = Ref(false)
  let receive : @spec.Receive = async fn() {
    @async.pause()
    if handled.val {
      @spec.HttpDisconnect
    } else {
      handled.val = true
      @spec.HttpRequest(body=b"", more_body=false)
    }
  }
  let send : @spec.Send = async fn(event) {
    @async.pause()
    match event {
      @spec.HttpResponseStart(status~, headers~, ..) => {
        println("response \{status}")
        for header in headers {
          println("  \{header.0}: \{header.1}")
        }
      }
      @spec.HttpResponseBody(body~, ..) =>
        println("body \{body.length()} octets")
      _ => ()
    }
  }
  traced(scope, receive, send)

  println("")
  for span in recorder.spans() {
    println("\{span.name}  \{span.duration()} ns  \{span.status}")
    for pair in span.attributes {
      println("  \{pair.0} = \{pair.1}")
    }
  }
}

///|
/// A clock that moves ten milliseconds per reading. A real service hands in its own
/// clock here; this one keeps the example's output the same on every run.
fn clock() -> () -> Int64 {
  let now = Ref(1_700_000_000_000_000_000L)
  () => {
    now.val = now.val + 10_000_000L
    now.val
  }
}

///|
fn random_bytes(width : Int32) -> Bytes {
  @moonrand.bytes(width, @system.source) catch {
    _ => abort("the platform has no entropy source")
  }
}

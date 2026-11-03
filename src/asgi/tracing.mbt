// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One server span per HTTP request, joined to the trace the request arrived with.
///
/// The layer does three things and no more: it reads `traceparent` and `baggage`
/// off the request, it opens a span of kind `Server` as a child of what it read, and
/// it writes the resulting context back on the response. A request that carried no
/// context starts a trace; one that carried a broken context also starts a trace,
/// because refusing the request over a header would be worse than a missing link in
/// the trace.
///
/// The span reaches the sink when the application returns, with the response status
/// on it. A request the application fails is recorded as an exception event before
/// the error is passed on to the server, which is what an ASGI server keeps.
pub(all) struct Tracing {
  tracer : @trace.Tracer
  /// The clock. This library never reads one itself, so a replay can drive a request
  /// through a timeline it chose and a service can hand in whichever clock it
  /// already trusts. Nanoseconds since any fixed origin.
  now : () -> Int64
  /// How a request is named. The default is the method and the path, which is what
  /// the middleware can see; a site that knows its routes should pass the route
  /// template instead, so that `/orders/42` and `/orders/43` are one span name
  /// rather than a thousand.
  name : (String, String) -> String
  /// Whether `baggage` rides along to the response. On by default: a hop that
  /// quietly drops what the caller attached is worse than one that never had it.
  baggage : Bool
  /// Paths to leave untraced. A health check every second is noise a backend pays
  /// for and nobody reads.
  ignore : Array[String]
}

///|
/// A tracing layer over `tracer`.
pub fn Tracing::new(
  tracer~ : @trace.Tracer,
  now~ : () -> Int64,
  name~ : (String, String) -> String = method_and_path,
  baggage~ : Bool = true,
  ignore~ : Array[String] = [],
) -> Tracing {
  { tracer, now, name, baggage, ignore, }
}

///|
/// The default span name: the method and the path, e.g. `GET /orders/42`.
pub fn method_and_path(http_method : String, path : String) -> String {
  http_method + " " + path
}

///|
/// Wraps an application in a server span per request. `wrap` is the `Layer` method,
/// so the middleware can sit in a stack beside the framework's own layers as well as
/// around a single application.
pub impl @mid.Layer for Tracing with fn wrap(self, app) {
  (scope, receive, send) => {
    guard scope is Http(http) else {
      // A WebSocket or a lifespan run is not an HTTP request: a server span for
      // either would need a different set of attributes, and guessing them here
      // would make the traces wrong rather than merely absent.
      app(scope, receive, send)
      return
    }
    guard !self.ignore.contains(http.path) else {
      app(scope, receive, send)
      return
    }
    let extracted = @propagate.extract(http.headers)
    let started = (self.now)()
    let span = self.start(http, extracted.context, started)
    let failure : Ref[Error?] = Ref(None)
    app(scope, receive, event => {
      let event = match event {
        @spec.HttpResponseStart(status~, headers~, trailers~) => {
          match span {
            Some(span) => {
              span.set_attribute(
                "http.response.status_code",
                @trace.Int(status.to_int64()),
              )
              // The semantic conventions leave a 5xx as the only status a server
              // span calls an error: a 404 is an answer, not a failure.
              if status >= 500 {
                span.set_status(@trace.Error("HTTP \{status}"))
              }
            }
            None => ()
          }
          let headers = match span {
            Some(span) => self.write_back(headers, span, extracted.baggage)
            None => headers
          }
          @spec.HttpResponseStart(status~, headers~, trailers~)
        }
        other => other
      }
      send(event)
    }) catch {
      error => failure.val = Some(error)
    }
    match span {
      None => ()
      Some(span) => {
        match failure.val {
          Some(error) =>
            span.record_exception(message="\{error}", at=(self.now)())
          None => ()
        }
        span.finish(at=(self.now)())
      }
    }
    match failure.val {
      Some(error) => raise error
      None => ()
    }
  }
}

///|
pub extend Tracing with @mid.Layer::{wrap}

///|
/// The server span for `http`, or `None` when the tracer's source of randomness
/// is broken — in which case the request runs untraced rather than failing, and
/// the failure shows up the next time anything else asks that generator for an id.
fn Tracing::start(
  self : Tracing,
  http : @spec.HttpScope,
  parent : @trace.TraceContext?,
  at : Int64,
) -> @trace.Span? {
  let attributes : Array[(String, @trace.Value)] = [
    ("http.request.method", @trace.Str(http.http_method)),
    ("url.path", @trace.Str(http.path)),
    ("url.scheme", @trace.Str(http.scheme)),
    ("network.protocol.version", @trace.Str(http.http_version)),
  ]
  let attributes = match http.server {
    Some((host, port)) => {
      let with_host = attributes.copy()
      with_host.push(("server.address", @trace.Str(host)))
      match port {
        Some(port) =>
          with_host.push(("server.port", @trace.Int(port.to_int64())))
        None => ()
      }
      with_host
    }
    None => attributes
  }
  let attributes = match http.client {
    Some((host, port)) => {
      let with_client = attributes.copy()
      with_client.push(("client.address", @trace.Str(host)))
      with_client.push(("client.port", @trace.Int(port.to_int64())))
      with_client
    }
    None => attributes
  }
  let span_name = (self.name)(http.http_method, http.path)
  try {
    match parent {
      Some(parent) =>
        Some(
          self.tracer.start(span_name, parent~, kind=Server, at~, attributes~),
        )
      None => Some(self.tracer.start(span_name, kind=Server, at~, attributes~))
    }
  } catch {
    _ => None
  }
}

///|
/// The response headers with this hop's context on them.
fn Tracing::write_back(
  self : Tracing,
  headers : Array[(String, String)],
  span : @trace.Span,
  baggage : @propagate.Baggage,
) -> Array[(String, String)] {
  @propagate.inject(headers, {
    context: Some(span.context()),
    baggage: if self.baggage {
      baggage
    } else {
      @propagate.empty_baggage
    },
  })
}

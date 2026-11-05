// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A transport over the network: one POST per request, on the HTTP client's shared
/// connection pool.
///
/// Kept out of `otlp` so that a program which only encodes a payload, or only
/// queues records, does not carry a TLS stack and a socket.
///
/// The request is a closure rather than a stored client, because the client's type
/// is the HTTP library's to name: keeping it out of this struct's signature is what
/// lets that library change without changing this one.
pub struct HttpTransport {
  post : async (@otlp.Request) -> (@otlp.Reply?, String)
}

///|
/// A transport that gives one request `timeout` milliseconds before abandoning it.
///
/// Headers travel on each `Request`, not here: one transport can carry a trace
/// request and a log request to two backends that want different keys.
pub fn HttpTransport::new(timeout~ : Int32 = 10000) -> HttpTransport {
  {
    post: async fn(request) {
      let outcome = Ok(
        @moonfetch.post(
          request.url[:],
          body=@moonfetch.Body::Text(request.body),
          headers=request.headers,
          timeout~,
        ),
      ) catch {
        error => Err("\{error}")
      }
      match outcome {
        Ok(reply) =>
          (
            Some({
              status: reply.status,
              headers: reply.headers,
              body: reply.text(),
            }),
            "",
          )
        Err(reason) => (None, reason)
      }
    },
  }
}

///|
/// Post the body and hand the reply back.
///
/// An HTTP status is a reply, whatever it says; only a request that produced
/// nothing to read becomes `Failed`.
pub impl @otlp.Transport for HttpTransport with fn send(self, request) {
  self.post_request(request)
}

///|
/// One request, with the failure this package's callers catch: a request that got
/// no reply at all.
async fn HttpTransport::post_request(
  self : HttpTransport,
  request : @otlp.Request,
) -> @otlp.Reply raise @otlp.Failed {
  let answer = (self.post)(request) catch { error => (None, "\{error}") }
  match answer {
    (Some(reply), _) => reply
    (None, reason) => raise @otlp.Failed::Unreachable(reason~)
  }
}

///|
pub extend HttpTransport with @otlp.Transport::{send}

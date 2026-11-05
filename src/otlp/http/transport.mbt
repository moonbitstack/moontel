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
/// How a transport packs the body it is handed.
///
/// The protocol lets a client compress and requires it to say so; a server must
/// accept both, so this is the sender's choice and nobody else's.
pub(all) enum Compression {
  /// The bytes the encoder produced, as they are.
  Plain
  /// The same bytes under gzip, with `Content-Encoding: gzip` on the request.
  Gzip
}

///|
/// A transport that gives one request `timeout` milliseconds before abandoning it,
/// and that packs the body the way `compression` says.
///
/// Headers travel on each `Request`, not here: one transport can carry a trace
/// request and a log request to two backends that want different keys.
pub fn HttpTransport::new(
  timeout~ : Int32 = 10000,
  compression~ : Compression = Plain,
) -> HttpTransport {
  {
    post: async fn(request) {
      let (body, headers) = payload(request, compression)
      let outcome = Ok(
        @moonfetch.post(request.url[:], body~, headers~, timeout~),
      ) catch {
        error => Err("\{error}")
      }
      match outcome {
        Ok(reply) =>
          (
            Some({
              status: reply.status,
              headers: reply.headers,
              body: reply.body,
            }),
            "",
          )
        Err(reason) => (None, reason)
      }
    },
  }
}

///|
/// The body as the wire takes it, and the headers that describe it.
///
/// The two are decided together on purpose: a gzipped body that does not say so is
/// a request no server can read, so the header is set here rather than left to a
/// caller who might forget it.
fn payload(
  request : @otlp.Request,
  compression : Compression,
) -> (@moonfetch.Body, Array[(String, String)]) {
  match compression {
    Plain => (@moonfetch.Body::Bytes(request.body), request.headers)
    Gzip =>
      (
        @moonfetch.Body::Bytes(@gzip.gzip(request.body[:])),
        with_encoding(request.headers, "gzip"),
      )
  }
}

///|
/// The headers with `Content-Encoding` set to `encoding`, replacing one a caller
/// wrote: the body decides the header, not the other way round.
fn with_encoding(
  headers : Array[(String, String)],
  encoding : String,
) -> Array[(String, String)] {
  let out = headers.filter(header => header.0.to_lower() != "content-encoding")
  out.push(("Content-Encoding", encoding))
  out
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

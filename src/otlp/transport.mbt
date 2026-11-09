// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The one way an export can fail: no reply at all.
///
/// A reply that says no is not an error here — it is a status code the retry rules
/// read. What has no status is a connection that never answered, which is why this
/// type carries a reason string rather than a number.
#derive(Debug)
pub(all) suberror Failed {
  Unreachable(reason~ : String)
}

///|
pub extend Failed with Debug::{to_repr}

///|
/// One OTLP request: where it goes, what it carries, and the headers that
/// authenticate it.
///
/// The body is bytes because OTLP has two encodings and only one of them is text:
/// the exporter picks the encoding and the transport carries what it was given.
pub(all) struct Request {
  url : String
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// What the server said back. The body is bytes for the same reason: a reply to a
/// protobuf request is protobuf.
pub(all) struct Reply {
  status : Int32
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// The reply body read as text, which is what a JSON reply is. Bytes that are not
/// UTF-8 come back with the bad sequences replaced rather than as an error: a
/// body that cannot be read is a body with nothing to say, and the status code
/// already said the important part.
pub fn Reply::text(self : Reply) -> String {
  @utf8.decode_lossy(self.body[:])
}

///|
/// One header of the reply, matched without regard to case, or `None`.
pub fn Reply::header(self : Reply, name : String) -> String? {
  let name = name.to_lower()
  for header in self.headers {
    if header.0.to_lower() == name {
      return Some(header.1)
    }
  }
  None
}

///|
/// How long the server asked to be left alone, in milliseconds, from the
/// `Retry-After` header.
///
/// The header carries either a number of seconds or an HTTP date, and both are
/// read here: a server that says "2026-11-05T10:00:00Z" means the same thing as
/// one that says "30", just less often. A date that has already passed is zero.
pub fn Reply::retry_after(self : Reply, now~ : Int64) -> Int64? {
  match self.header("retry-after") {
    Some(value) => retry_after_milliseconds(value[:], now~)
    None => None
  }
}

///|
/// How many records of this signal the server said it refused, from the
/// `partialSuccess` field of the reply body.
///
/// A partial success is an accepted request: the specification says the client
/// MUST NOT retry it, and it says the count is what tells an operator that some
/// data was turned away. A body that is not JSON, or carries no `partialSuccess`,
/// answers `None` rather than zero, because "said nothing" and "refused none"
/// differ. Inside one, a count left out is zero: the JSON mapping omits zeros.
pub fn Reply::rejected(self : Reply) -> Int32? {
  rejected_in_json(self.text())
}

///|
/// The same count, read out of a reply body this side already holds as text.
///
/// The JSON encoding and `Reply::rejected` are the same reader; keeping it here
/// means a `partialSuccess` the protocol spells one way is not read two ways.
fn rejected_in_json(text : String) -> Int32? {
  let parsed = @json.parse(text[:], preserve_number_repr=true) catch {
    _ => return None
  }
  let success = match parsed {
    @json.Object(fields) => fields.get("partialSuccess")
    _ => None
  }
  let fields = match success {
    Some(@json.Object(fields)) => fields
    _ => return None
  }
  for name in ["rejectedSpans", "rejectedDataPoints", "rejectedLogRecords"] {
    match fields.get(name) {
      // The protobuf JSON mapping writes 64-bit integers as decimal strings, and
      // some servers write them as numbers; both are read.
      Some(@json.Number(value, ..)) => return Some(value.to_int())
      Some(@json.String(text)) =>
        match parse_decimal(text[:]) {
          Some(value) => return Some(value.to_int())
          None => return None
        }
      _ => ()
    }
  }
  Some(0)
}

///|
/// Sends one request and hands back the reply.
///
/// The seam that keeps this package free of a transport: an implementation over
/// sockets is `otlp/http`, and a test supplies one that answers from a script.
/// A transport raises `Failed` only when the request produced no reply; an HTTP
/// error status is a reply and belongs in `Reply::status`.
pub(open) trait Transport {
  async fn send(Self, Request) -> Reply raise Failed
}

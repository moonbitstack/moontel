// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How one request body is written.
///
/// An exporter needs four things from an encoding and they belong together: the
/// encoder, the `Content-Type` the body is sent under, and the way a reply's count
/// of refused records is read. All three move with the encoding, so a transport
/// cannot end up announcing one and carrying the other.
///
/// This package writes the JSON mapping and nothing else. Binary protobuf is its
/// own package, `otlp/binary`, because it needs the protocol's schema and a runtime
/// to walk it; a program that sends JSON should not compile either.
pub(open) trait Encoding {
  /// Which of the two encodings this is, and with it the media type.
  fn format(Self) -> BodyFormat
  /// One `/v1/traces` request body.
  fn traces(Self, Array[@trace.SpanData], Resource, Scope) -> Bytes
  /// One `/v1/logs` request body.
  fn logs(Self, Array[@log.LogRecord], Resource, Scope) -> Bytes
  /// One `/v1/metrics` request body.
  fn metrics(Self, Array[Metric], Resource, Scope) -> Bytes
  /// How many records a reply says the server refused.
  ///
  /// `None` when the reply says nothing: an accepted request that lost some data is
  /// still an accepted request, and "said nothing" is not "refused none".
  fn rejected(Self, Bytes) -> Int32?
}

///|
/// The protobuf JSON mapping, which is what this package writes on its own.
pub struct JsonEncoding {}

///|
/// The JSON encoding, ready to hand to an exporter.
pub let json : &Encoding = JsonEncoding::{ }

///|
impl Encoding for JsonEncoding with fn format(_self) {
  Json
}

///|
impl Encoding for JsonEncoding with fn traces(_self, spans, resource, scope) {
  @utf8.encode(encode_traces(spans, resource~, scope~))
}

///|
impl Encoding for JsonEncoding with fn logs(_self, records, resource, scope) {
  @utf8.encode(encode_logs(records, resource~, scope~))
}

///|
impl Encoding for JsonEncoding with fn metrics(_self, metrics, resource, scope) {
  @utf8.encode(encode_metrics(metrics, resource~, scope~))
}

///|
impl Encoding for JsonEncoding with fn rejected(_self, body) {
  rejected_in_json(@utf8.decode_lossy(body))
}

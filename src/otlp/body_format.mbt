// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Which of the two OTLP encodings a request body uses.
///
/// The protocol defines binary protobuf and the JSON mapping of it, and says an
/// exporter must be able to send protobuf and may send JSON. Both are here; the
/// JSON one is what this library sent first, and it is still the default because a
/// body a person can read in a log is worth something while a library is young.
pub(all) enum BodyFormat {
  /// The protobuf JSON mapping: `application/json`.
  Json
  /// Binary protobuf: `application/x-protobuf`.
  Protobuf
}

///|
/// The `Content-Type` a body of this format is sent under.
pub fn BodyFormat::media_type(self : BodyFormat) -> String {
  match self {
    Json => "application/json"
    Protobuf => "application/x-protobuf"
  }
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How much body this side will send in one request, and how much of a reply it
/// will read.
///
/// Both bounds are the protocol's. OTLP's "OTLP/HTTP Request" section says a client
/// SHOULD limit the body it sends — 64 MiB is the recommended default — and MUST NOT
/// make the request when the limit is exceeded. Its "OTLP/HTTP Response" section says
/// a client MUST limit what it parses back, recommends 4 MiB, and calls a reply over
/// the limit a failure that retrying cannot fix.
///
/// A program that sends large attribute values or long log bodies raises `request`;
/// one that talks to a collector which answers with a page of diagnostics lowers
/// `response`.
pub(all) struct BodyLimits {
  /// The most bytes one request may carry, before any compression.
  request : Int32
  /// The most bytes of a reply this side will read.
  response : Int32
}

///|
/// The bounds the specification recommends: 64 MiB out, 4 MiB back.
pub let recommended_body_limits : BodyLimits = {
  request: 64 * 1024 * 1024,
  response: 4 * 1024 * 1024,
}

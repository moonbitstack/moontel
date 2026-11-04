// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The header `traceparent` travels in (W3C Trace Context §3.2.1). Lowercase on
/// the wire; lookups here compare without regard to case.
pub let traceparent_header : String = "traceparent"

///|
/// The header `tracestate` travels in (W3C Trace Context §3.3.1).
pub let tracestate_header : String = "tracestate"

///|
/// The header `baggage` travels in (W3C Baggage §3.2.1).
pub let baggage_header : String = "baggage"

///|
/// A parsed `traceparent`, plus the vendor state that came with it.
///
/// `version` is kept even though nothing here acts on it: a caller debugging a
/// failed handshake wants to know which version of the header the other side
/// spoke, and a version above zero may one day carry fields this library does not
/// read.
///
/// The ids are validated on the way in — sixteen and eight octets, neither all
/// zero — because a context that fails that is not a trace to join, and passing it
/// on would make a broken hop look like a working one.
pub fn parse(
  traceparent : StringView,
  tracestate? : StringView,
) -> @trace.TraceContext raise @trace.Refused {
  let context = parse_traceparent(traceparent)
  let state = match tracestate {
    None => @trace.empty_trace_state
    Some(text) => @trace.TraceState::parse(text)
  }
  { ..context, state, }
}

///|
/// Parse a `traceparent` header value, without any vendor state.
///
/// The grammar is W3C Trace Context §3.2:
///
/// ```text
/// version(2)-trace-id(32)-parent-id(16)-trace-flags(2)
/// ```
///
/// A version this library does not know may append fields, but only after a `-`:
/// `00` headers end at 55 characters, and `00-…-01.whatever` is refused rather
/// than read as a version-0 header with a suffix. Version `ff` is refused by the
/// specification, as is an all-zero id.
///
/// Whitespace around the value is dropped. HTTP allows OWS around a field value,
/// and W3C Trace Context's examples send it; whitespace anywhere inside is refused
/// as the illegal character it is.
pub fn parse_traceparent(
  input : StringView,
) -> @trace.TraceContext raise @trace.Refused {
  let text = strip_ows(input)
  let n = text.length()
  if n < 55 {
    raise @trace.Refused::Field(at=n, want="the 55 characters of a traceparent")
  }
  let version = hex_byte(text, 0)
  if version == 0xff {
    raise @trace.Refused::Field(at=0, want="a version below ff")
  }
  expect_dash(text, 2)
  let trace_id = hex_id(text, 3, 32)
  expect_dash(text, 35)
  let span_id = hex_id(text, 36, 16)
  expect_dash(text, 52)
  let flags = hex_byte(text, 53)
  if n > 55 {
    // A future version may add fields, and only after a dash. Refusing a version-0
    // header with a suffix keeps a typo in the flags from looking like a newer
    // header that this hop can safely ignore.
    if version == 0 {
      raise @trace.Refused::Field(at=55, want="the end of the header")
    }
    if text[55].to_int() != 0x2d {
      raise @trace.Refused::Field(at=55, want="a dash before the extra fields")
    }
  }
  @trace.TraceContext::new(
    trace_id~,
    span_id~,
    flags=flags.to_byte(),
    state=@trace.empty_trace_state,
    remote=true,
  )
}

///|
/// Parse a `tracestate` header value. The grammar lives with the type that holds
/// the state; this is the name a caller reaching for the header uses.
pub fn parse_tracestate(
  input : StringView,
) -> @trace.TraceState raise @trace.Refused {
  @trace.TraceState::parse(input)
}

///|
fn expect_dash(text : StringView, at : Int32) -> Unit raise @trace.Refused {
  if text[at].to_int() != 0x2d {
    raise @trace.Refused::Field(at~, want="a dash")
  }
}

///|
/// Two hexadecimal digits at `at`, lowercase only, as a number.
fn hex_byte(text : StringView, at : Int32) -> Int32 raise @trace.Refused {
  let high = hex_nibble(text, at)
  let low = hex_nibble(text, at + 1)
  (high << 4) | low
}

///|
/// An id of `width` hexadecimal digits starting at `at`, decoded to octets.
fn hex_id(
  text : StringView,
  at : Int32,
  width : Int32,
) -> Bytes raise @trace.Refused {
  let bytes : Array[Byte] = []
  let mut non_zero = false
  let mut i = 0
  while i < width {
    let high = hex_nibble(text, at + i)
    let low = hex_nibble(text, at + i + 1)
    let byte = ((high << 4) | low).to_byte()
    if byte != b'\x00' {
      non_zero = true
    }
    bytes.push(byte)
    i = i + 2
  }
  if !non_zero {
    raise @trace.Refused::Zero(at~)
  }
  Bytes::from_array(bytes)
}

///|
/// One lowercase hexadecimal digit. Uppercase is refused: W3C Trace Context writes
/// the fields in lowercase, and a hop that accepted both spellings would hand the
/// next hop a value it might not accept.
fn hex_nibble(text : StringView, at : Int32) -> Int32 raise @trace.Refused {
  let c = text[at].to_int()
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else {
    raise @trace.Refused::NotHex(at~)
  }
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Why a header, an id or a span id source was refused.
///
/// One error type for the whole module: a caller parsing an inbound
/// `traceparent` and a caller handing the tracer a broken source of randomness
/// both have one thing to catch.
pub(all) suberror Refused {
  /// A field that is not what the grammar asks for, at this offset in the input.
  Field(at~ : Int32, want~ : String)
  /// A character that has to be a lowercase hexadecimal digit and is not, at
  /// this offset. Uppercase is refused here because W3C Trace Context writes the
  /// fields in lowercase, and a parser that accepted both would let two spellings
  /// of one trace id into the same backend.
  NotHex(at~ : Int32)
  /// An id that is all zero octets, which W3C Trace Context declares invalid.
  Zero(at~ : Int32)
  /// More list-members than the limit allows.
  TooMany(limit~ : Int32, got~ : Int32)
  /// A header longer than the limit, in octets.
  TooLong(limit~ : Int32, got~ : Int32)
  /// A source of randomness that did not hand back the number of octets asked
  /// for: `rand(16)` owes sixteen, and anything else is a broken generator rather
  /// than an id this library can guess at.
  Ids(want~ : Int32, got~ : Int32)
} derive(Eq, Debug)

///|
pub extend Refused with Eq::{equal, not_equal}

///|
pub extend Refused with Debug::{to_repr}

///|
/// The `sampled` bit of `traceparent`'s flags field (W3C Trace Context §3.2.2.5).
pub let sampled_flag : Byte = b'\x01'

///|
/// The `random` bit W3C Trace Context level 2 uses to say a trace id was drawn
/// at random. Carried through a hop unchanged; this library does not read it.
pub let random_flag : Byte = b'\x02'

///|
/// The identity of a span: the trace it belongs to, its own id, the flags
/// travelling with it, and the vendor state riding along.
///
/// Ids are octets, not text: sixteen for the trace and eight for the span, as
/// W3C Trace Context lays them out. Hexadecimal is a spelling used at the wire
/// and in logs, and it is produced there rather than stored here.
pub(all) struct TraceContext {
  trace_id : Bytes
  span_id : Bytes
  flags : Byte
  state : TraceState
} derive(Eq, Debug)

///|
pub extend TraceContext with Eq::{equal, not_equal}

///|
pub extend TraceContext with Debug::{to_repr}

///|
/// Build a context from ids the caller already has. Nothing is validated: this is
/// the shape a tracer mints and a sink reads, and a caller holding a `Span`
/// already has a valid one. A context read off the wire comes from `parse`
/// instead, which does validate.
pub fn TraceContext::new(
  trace_id~ : Bytes,
  span_id~ : Bytes,
  flags~ : Byte = b'\x00',
  state~ : TraceState = empty_trace_state,
) -> TraceContext {
  { trace_id, span_id, flags, state, }
}

///|
/// Whether the trace id is sixteen octets and the span id eight, neither all
/// zero. A context that fails this is not a trace to join.
pub fn TraceContext::is_valid(self : TraceContext) -> Bool {
  is_id(self.trace_id, 16) && is_id(self.span_id, 8)
}

///|
/// Whether the `sampled` bit is set: the flag that says this span, and the
/// children that carry it, are wanted by whoever reads the traces.
pub fn TraceContext::sampled(self : TraceContext) -> Bool {
  (self.flags & sampled_flag) != b'\x00'
}

///|
/// The same context with the `sampled` bit set or cleared, which is what a
/// sampler's decision turns into. Every other flag travels as it came: a version
/// of the header this library has not met may have put meaning in them.
pub fn TraceContext::with_sampled(
  self : TraceContext,
  sampled~ : Bool,
) -> TraceContext {
  {
    ..self,
    flags: if sampled {
      self.flags | sampled_flag
    } else {
      self.flags & b'\xfe'
    },
  }
}

///|
/// The `traceparent` header value for this context: version `00`, the trace id,
/// the span id, and the flags, in lowercase hexadecimal.
pub fn TraceContext::to_traceparent(self : TraceContext) -> String {
  let out = StringBuilder()
  out.write_string("00-")
  out.write_string(@base16.encode(self.trace_id[:]))
  out.write_char('-')
  out.write_string(@base16.encode(self.span_id[:]))
  out.write_char('-')
  let flags = self.flags.to_int()
  out.write_char(hex_digit(flags >> 4))
  out.write_char(hex_digit(flags & 0x0f))
  out.to_string()
}

///|
/// Vendor state travelling with the trace, as an ordered list of at most 32
/// list-members (W3C Trace Context §3.3.1).
///
/// It is a list, not a map: the order is what a hop writes back, the first member
/// belongs to the closest hop, and two members may not share a key. The update
/// operations return a new state rather than editing this one, so that a caller
/// holding the state that arrived cannot change what it arrived as.
pub(all) struct TraceState {
  members : Array[(String, String)]
} derive(Eq, Debug)

///|
pub extend TraceState with Eq::{equal, not_equal}

///|
pub extend TraceState with Debug::{to_repr}

///|
/// No vendor state: what a new trace starts with, and what a hop that carries
/// nothing forward hands on.
pub let empty_trace_state : TraceState = { members: [], }

///|
/// The list-members W3C Trace Context allows in one `tracestate` (§3.3.1).
pub let tracestate_limit : Int32 = 32

///|
/// How many list-members the state carries.
pub fn TraceState::len(self : TraceState) -> Int32 {
  self.members.length()
}

///|
pub fn TraceState::is_empty(self : TraceState) -> Bool {
  self.members.is_empty()
}

///|
/// The value `key` is bound to, or `None` when the state has no such member.
pub fn TraceState::get(self : TraceState, key : String) -> String? {
  for entry in self.members {
    if entry.0 == key {
      return Some(entry.1)
    }
  }
  None
}

///|
/// The header value: members in order, `key=value`, comma-separated, with no
/// whitespace (W3C Trace Context §3.3.1.2). Empty when there is no state, which on
/// the wire is the same as no header being sent.
pub fn TraceState::to_header(self : TraceState) -> String {
  let out = StringBuilder()
  for i, entry in self.members {
    if i > 0 {
      out.write_char(',')
    }
    out.write_string(entry.0)
    out.write_char('=')
    out.write_string(entry.1)
  }
  out.to_string()
}

///|
/// Parse a `tracestate` header value.
///
/// Strict on purpose: a list-member that does not match the grammar or a list
/// longer than 32 members refuses the whole header. A hop that kept the parseable
/// half of a broken `tracestate` would hand the next hop something the sender never
/// wrote, and W3C Trace Context §3.3.1 asks for the header to be dropped instead.
///
/// A key that appears twice is the one thing handled member by member: the first
/// member with that key wins and the later one is dropped, which is the choice W3C
/// Trace Context level 2 allows ("pass the duplicate on as-is or drop one of
/// them") and the one the interoperability suite's reference checker makes.
///
/// Whitespace before a member and after a value is dropped, as is whitespace
/// around the commas; whitespace anywhere else is part of a key or a value that
/// the grammar does not allow.
pub fn TraceState::parse(input : StringView) -> TraceState raise Refused {
  let members : Array[(String, String)] = []
  if input.length() == 0 {
    return { members, }
  }
  let n = input.length()
  let mut start = 0
  let mut i = 0
  while i <= n {
    if i == n || input[i].to_int() == 0x2c {
      let (lo, hi) = trim(input, start, i)
      if lo < hi {
        let ((key_lo, key_hi), (value_lo, value_hi)) = split_member(
          input, lo, hi,
        )
        check_key(input, key_lo, key_hi)
        check_value(input, value_lo, value_hi)
        let key = input.exact_view(start=key_lo, end=key_hi).to_owned()
        if !members.any(entry => entry.0 == key) {
          members.push(
            (key, input.exact_view(start=value_lo, end=value_hi).to_owned()),
          )
        }
        if members.length() > tracestate_limit {
          raise Refused::TooMany(limit=tracestate_limit, got=members.length())
        }
      }
      start = i + 1
    }
    i = i + 1
  }
  { members, }
}

///|
/// The same state with `key` set to `value` as the member closest to this hop
/// (W3C Trace Context §3.3.1): an existing member with that key is replaced rather
/// than moved, and a list already at 32 members drops its rightmost.
///
/// Building a header to send means adding your own entry to what came in, which is
/// the one mutation a hop is allowed to make.
pub fn TraceState::insert(
  self : TraceState,
  key~ : String,
  value~ : String,
) -> TraceState raise Refused {
  check_key(key[:], 0, key.length())
  check_value(value[:], 0, value.length())
  let members : Array[(String, String)] = [(key, value)]
  for entry in self.members {
    if entry.0 != key {
      members.push(entry)
    }
  }
  while members.length() > tracestate_limit {
    members.pop() |> ignore
  }
  { members, }
}

///|
/// The same state without the member `key` names, and unchanged when there is
/// none.
pub fn TraceState::delete(self : TraceState, key : String) -> TraceState {
  { members: self.members.filter(entry => entry.0 != key), }
}

// ------------------------------------------------------------------ internals

///|
/// Whether `bytes` is exactly `width` octets and not all zero, the shape both
/// W3C Trace Context and OpenTelemetry demand of an id.
fn is_id(bytes : Bytes, width : Int32) -> Bool {
  if bytes.length() != width {
    return false
  }
  for i in 0..<width {
    if bytes[i] != b'\x00' {
      return true
    }
  }
  false
}

///|
/// One lowercase hexadecimal digit, for the two-nibble fields the header writes
/// itself rather than handing to the base16 encoder.
fn hex_digit(value : Int32) -> Char {
  if value < 10 {
    (0x30 + value).unsafe_to_char()
  } else {
    (0x61 + value - 10).unsafe_to_char()
  }
}

///|
/// The bounds of `s[start..<end]` with leading and trailing OWS removed, as a pair
/// of offsets so that a caller can keep pointing into the original string.
fn trim(s : StringView, start : Int32, end : Int32) -> (Int32, Int32) {
  let mut lo = start
  let mut hi = end
  while lo < hi && is_ows(s[lo].to_int()) {
    lo = lo + 1
  }
  while hi > lo && is_ows(s[hi - 1].to_int()) {
    hi = hi - 1
  }
  (lo, hi)
}

///|
fn is_ows(c : Int32) -> Bool {
  c == 0x20 || c == 0x09
}

///|
/// Split one list-member at its first `=` (W3C Trace Context §3.3.1). Nothing is
/// trimmed around the `=`: the grammar puts no whitespace there, so `foo =1` is a
/// key with a space in it rather than a member to be repaired.
fn split_member(
  s : StringView,
  start : Int32,
  end : Int32,
) -> ((Int32, Int32), (Int32, Int32)) raise Refused {
  let mut i = start
  while i < end {
    if s[i].to_int() == 0x3d {
      return ((start, i), (i + 1, end))
    }
    i = i + 1
  }
  raise Refused::Field(at=start, want="key=value")
}

///|
/// W3C Trace Context §3.3.1.1 `key`, over `s[start..<end]`.
fn check_key(s : StringView, start : Int32, end : Int32) -> Unit raise Refused {
  if start == end {
    raise Refused::Field(at=start, want="a tracestate key")
  }
  // A key is a simple key, or a tenant id and a system id around one `@`. Each
  // half has its own length limit and its own first-character rule, so the two are
  // checked as the two halves they are.
  match find_at(s, start, end) {
    None =>
      check_key_part(
        s,
        start,
        end,
        255,
        lower=true,
        at=start,
        what="a simple key",
      )
    Some(pos) => {
      check_key_part(
        s,
        start,
        pos,
        240,
        lower=false,
        at=start,
        what="a tenant id",
      )
      check_key_part(
        s,
        pos + 1,
        end,
        13,
        lower=true,
        at=pos + 1,
        what="a system id",
      )
    }
  }
}

///|
/// The offset of the first `@` in `s[start..<end]`, if any. A key has at most one
/// the grammar allows, and a second one falls out as an illegal character in the
/// system id.
fn find_at(s : StringView, start : Int32, end : Int32) -> Int32? {
  let mut i = start
  while i < end {
    if s[i].to_int() == 0x40 {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// One half of a key: a first character, then up to `rest` characters from
/// `lcalpha / DIGIT / "_" / "-" / "*" / "/"`. The first character is a lowercase
/// letter, or for a tenant id a digit too.
fn check_key_part(
  s : StringView,
  start : Int32,
  end : Int32,
  rest : Int32,
  lower~ : Bool,
  at~ : Int32,
  what~ : String,
) -> Unit raise Refused {
  if start == end {
    raise Refused::Field(at~, want=what)
  }
  if end - start - 1 > rest {
    raise Refused::TooLong(limit=rest + 1, got=end - start)
  }
  let first = s[start].to_int()
  if !(is_lcalpha(first) || (!lower && is_digit(first))) {
    raise Refused::Field(at=start, want=what)
  }
  let mut i = start + 1
  while i < end {
    let c = s[i].to_int()
    if !(is_lcalpha(c) ||
      is_digit(c) ||
      c == 0x5f ||
      c == 0x2d ||
      c == 0x2a ||
      c == 0x2f) {
      raise Refused::Field(at=i, want="a key character")
    }
    i = i + 1
  }
}

///|
/// W3C Trace Context §3.3.1.1 `value`: up to 256 characters from
/// `%x20-2B / %x2D-3C / %x3E-7E`, and the last one may not be a space.
fn check_value(
  s : StringView,
  start : Int32,
  end : Int32,
) -> Unit raise Refused {
  if start == end {
    raise Refused::Field(at=start, want="a tracestate value")
  }
  if end - start > 256 {
    raise Refused::TooLong(limit=256, got=end - start)
  }
  let mut i = start
  while i < end {
    let c = s[i].to_int()
    if c < 0x20 || c > 0x7e || c == 0x2c || c == 0x3d {
      raise Refused::Field(at=i, want="a tracestate value character")
    }
    i = i + 1
  }
  if s[end - 1].to_int() == 0x20 {
    raise Refused::Field(
      at=end - 1,
      want="a value that does not end in a space",
    )
  }
}

///|
fn is_lcalpha(c : Int32) -> Bool {
  c >= 0x61 && c <= 0x7a
}

///|
fn is_digit(c : Int32) -> Bool {
  c >= 0x30 && c <= 0x39
}

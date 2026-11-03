// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One metadata entry on a baggage member: `key` or `key=value`, after the `;` of
/// a list-member (W3C Baggage §3.2.2.3). The specification gives properties no
/// meaning of their own; they are carried so a hop that does not understand one
/// can pass it on unchanged.
pub(all) struct Property {
  key : String
  /// `None` for a property written as a bare key.
  value : String?
} derive(Eq, Debug)

///|
pub extend Property with Eq::{equal, not_equal}

///|
pub extend Property with Debug::{to_repr}

///|
/// One baggage entry: a key, a value, and any properties attached to it.
///
/// The value is stored decoded, as text. The wire form is percent-encoded ASCII,
/// and decoding is where a hop stops caring how the value was spelled.
pub(all) struct Member {
  key : String
  value : String
  properties : Array[Property]
} derive(Eq, Debug)

///|
pub extend Member with Eq::{equal, not_equal}

///|
pub extend Member with Debug::{to_repr}

///|
/// Keys and values carried alongside a trace, ordered, with duplicates allowed.
///
/// Order is part of the data: W3C Baggage asks a hop to preserve the order of
/// duplicate entries when it mutates the list, so this is an array rather than a
/// map. `get` answers with the first member carrying a key, which is the one a
/// reader asking "what did the caller say" wants.
pub(all) struct Baggage {
  members : Array[Member]
} derive(Eq, Debug)

///|
pub extend Baggage with Eq::{equal, not_equal}

///|
pub extend Baggage with Debug::{to_repr}

///|
/// Nothing carried, which a request with no `baggage` header arrives with.
pub let empty_baggage : Baggage = { members: [], }

///|
/// The list-members W3C Baggage §3.2.1.3 requires a platform to propagate: a
/// header of 64 members or fewer must survive the hop whole.
pub let baggage_member_limit : Int32 = 64

///|
/// The size W3C Baggage §3.2.1.3 requires a platform to propagate: 8192 octets of
/// combined header.
pub let baggage_byte_limit : Int32 = 8192

///|
/// A bag carrying `members`, in the order given.
pub fn Baggage::new(members~ : Array[Member] = []) -> Baggage {
  { members, }
}

///|
/// How many members the bag carries.
pub fn Baggage::len(self : Baggage) -> Int32 {
  self.members.length()
}

///|
pub fn Baggage::is_empty(self : Baggage) -> Bool {
  self.members.is_empty()
}

///|
/// The value of the first member keyed `key`, or `None`.
pub fn Baggage::get(self : Baggage, key : String) -> String? {
  for entry in self.members {
    if entry.key == key {
      return Some(entry.value)
    }
  }
  None
}

///|
/// The same bag with `member` added at the end, past the member limit keeping the
/// bag as it was rather than growing an unusable header.
pub fn Baggage::add(self : Baggage, entry : Member) -> Baggage {
  if self.members.length() >= baggage_member_limit {
    return self
  }
  let members = self.members.copy()
  members.push(entry)
  { members, }
}

///|
/// Parse a `baggage` header value (W3C Baggage §3.2).
///
/// Whitespace around a member, around an `=`, and around the commas is dropped;
/// a member that does not match the grammar refuses the whole header, because a
/// half-read bag is a bag the next hop would rewrite. Values are percent-decoded
/// and sequences that are not UTF-8 become `U+FFFD`, as §3.2.2.2 asks.
///
/// The limits are the ones a platform must propagate — 64 members and 8192 octets
/// — checked against the value as it arrived, and enforced by refusing rather than
/// truncating: a caller that receives a bag too big to be legal has received
/// something a middlebox either wrote or mangled, and guessing which members it
/// meant is not this library's business.
pub fn Baggage::parse(input : StringView) -> Baggage raise @trace.Refused {
  let members : Array[Member] = []
  let bytes = @utf8.encode(input)
  if bytes.length() > baggage_byte_limit {
    raise @trace.Refused::TooLong(limit=baggage_byte_limit, got=bytes.length())
  }
  let mut start = 0
  let mut i = 0
  let n = input.length()
  while i <= n {
    if i == n || input[i].to_int() == 0x2c {
      let (lo, hi) = trim(input, start, i)
      if lo < hi {
        // The byte limit is on the header, the member limit on the list: both are
        // checked as the list is built so that a header of a thousand empty
        // members is refused too.
        if members.length() >= baggage_member_limit {
          raise @trace.Refused::TooMany(
            limit=baggage_member_limit,
            got=members.length() + 1,
          )
        }
        members.push(parse_member(input, lo, hi))
      }
      start = i + 1
    }
    i = i + 1
  }
  { members, }
}

///|
/// The header value: members in order, `key=value` with properties after `;`, and
/// every character outside the `baggage-octet` set percent-encoded in uppercase
/// hexadecimal (W3C Baggage §3.2.2.2). Empty when the bag is empty, which on the
/// wire is the same as sending no header.
pub fn Baggage::to_header(self : Baggage) -> String {
  let out = StringBuilder()
  for i, entry in self.members {
    if i > 0 {
      out.write_char(',')
    }
    out.write_string(entry.key)
    out.write_char('=')
    encode_value(entry.value, out)
    for property in entry.properties {
      out.write_char(';')
      out.write_string(property.key)
      match property.value {
        Some(value) => {
          out.write_char('=')
          encode_value(value, out)
        }
        None => ()
      }
    }
  }
  out.to_string()
}

// ------------------------------------------------------------------ internals

///|
/// One list-member over `s[start..<end]`: `key = value *( ; property )`.
fn parse_member(
  s : StringView,
  start : Int32,
  end : Int32,
) -> Member raise @trace.Refused {
  // A `;` cannot appear inside a value — it is not a `baggage-octet` — so the
  // first one ends the key and value part.
  let mut semicolon = None
  let mut i = start
  while i < end {
    if s[i].to_int() == 0x3b {
      semicolon = Some(i)
      break
    }
    i = i + 1
  }
  let head_end = match semicolon {
    Some(position) => position
    None => end
  }
  let mut equals = None
  let mut j = start
  while j < head_end {
    if s[j].to_int() == 0x3d {
      equals = Some(j)
      break
    }
    j = j + 1
  }
  let position = match equals {
    Some(position) => position
    None => raise @trace.Refused::Field(at=start, want="key=value")
  }
  let (key_lo, key_hi) = trim(s, start, position)
  check_key(s, key_lo, key_hi)
  let (value_lo, value_hi) = trim(s, position + 1, head_end)
  check_value(s, value_lo, value_hi)
  let properties : Array[Property] = []
  if semicolon is Some(position) {
    // Properties are `;`-separated to the end of the member, and a `;` cannot
    // appear inside a value, so scanning for the next one is unambiguous.
    let mut from = position + 1
    while from < end {
      let mut next = from
      while next < end && s[next].to_int() != 0x3b {
        next = next + 1
      }
      let (lo, hi) = trim(s, from, next)
      if lo < hi {
        properties.push(parse_property(s, lo, hi))
      }
      from = next + 1
    }
  }
  {
    key: s.exact_view(start=key_lo, end=key_hi).to_owned(),
    value: percent_decode(s.exact_view(start=value_lo, end=value_hi)),
    properties,
  }
}

///|
/// One property over `s[start..<end]`: `key` or `key=value`.
fn parse_property(
  s : StringView,
  start : Int32,
  end : Int32,
) -> Property raise @trace.Refused {
  let mut equals = None
  let mut i = start
  while i < end {
    if s[i].to_int() == 0x3d {
      equals = Some(i)
      break
    }
    i = i + 1
  }
  match equals {
    None => {
      let (lo, hi) = trim(s, start, end)
      check_key(s, lo, hi)
      { key: s.exact_view(start=lo, end=hi).to_owned(), value: None, }
    }
    Some(position) => {
      let (key_lo, key_hi) = trim(s, start, position)
      check_key(s, key_lo, key_hi)
      let (value_lo, value_hi) = trim(s, position + 1, end)
      check_value(s, value_lo, value_hi)
      {
        key: s.exact_view(start=key_lo, end=key_hi).to_owned(),
        value: Some(percent_decode(s.exact_view(start=value_lo, end=value_hi))),
      }
    }
  }
}

///|
/// A key is an RFC 7230 §3.2.6 `token`: one or more `tchar`.
fn check_key(
  s : StringView,
  start : Int32,
  end : Int32,
) -> Unit raise @trace.Refused {
  if start == end {
    raise @trace.Refused::Field(at=start, want="a baggage key")
  }
  let mut i = start
  while i < end {
    let c = s[i].to_int()
    let is_tchar = (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      c == 0x21 ||
      c == 0x23 ||
      c == 0x24 ||
      c == 0x25 ||
      c == 0x26 ||
      c == 0x27 ||
      c == 0x2a ||
      c == 0x2b ||
      c == 0x2d ||
      c == 0x2e ||
      c == 0x5e ||
      c == 0x5f ||
      c == 0x60 ||
      c == 0x7c ||
      c == 0x7e
    if !is_tchar {
      raise @trace.Refused::Field(at=i, want="a baggage key character")
    }
    i = i + 1
  }
}

///|
/// A value is zero or more `baggage-octet`, which may be empty: `k=` is a member
/// whose value is the empty string.
fn check_value(
  s : StringView,
  start : Int32,
  end : Int32,
) -> Unit raise @trace.Refused {
  let mut i = start
  while i < end {
    if !is_baggage_octet(s[i].to_int()) {
      raise @trace.Refused::Field(at=i, want="a baggage value character")
    }
    i = i + 1
  }
}

///|
/// `%x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E`: printable ASCII without the
/// double quote, comma, semicolon and backslash (W3C Baggage §3.2.2.1).
fn is_baggage_octet(c : Int32) -> Bool {
  if c == 0x21 {
    return true
  }
  if c >= 0x23 && c <= 0x2b {
    return true
  }
  if c >= 0x2d && c <= 0x3a {
    return true
  }
  if c >= 0x3c && c <= 0x5b {
    return true
  }
  c >= 0x5d && c <= 0x7e
}

///|
/// Percent-decode a value (RFC 3986 §2.1), leaving everything else as the UTF-8 it
/// arrived as. A sequence that does not decode to UTF-8 becomes `U+FFFD`, which is
/// what W3C Baggage §3.2.2.2 asks for rather than refusing the header.
fn percent_decode(text : StringView) -> String {
  let raw = @utf8.encode(text)
  let out : Array[Byte] = []
  let n = raw.length()
  let mut i = 0
  while i < n {
    let byte = raw[i]
    if byte == b'%' && i + 2 < n {
      let high = hex_value(raw[i + 1])
      let low = hex_value(raw[i + 2])
      match (high, low) {
        (Some(high), Some(low)) => {
          out.push(((high << 4) | low).to_byte())
          i = i + 3
          continue
        }
        _ => ()
      }
    }
    out.push(byte)
    i = i + 1
  }
  @utf8.decode_lossy(Bytes::from_array(out))
}

///|
/// One hexadecimal digit of either case, or `None`.
fn hex_value(byte : Byte) -> Int32? {
  let c = byte.to_int()
  if c >= 0x30 && c <= 0x39 {
    Some(c - 0x30)
  } else if c >= 0x41 && c <= 0x46 {
    Some(c - 0x41 + 10)
  } else if c >= 0x61 && c <= 0x66 {
    Some(c - 0x61 + 10)
  } else {
    None
  }
}

///|
/// Percent-encode a value for the wire: every octet outside `baggage-octet`, and
/// `%` itself, in uppercase hexadecimal.
fn encode_value(value : String, out : StringBuilder) -> Unit {
  let raw = @utf8.encode(value)
  for byte in raw {
    let c = byte.to_int()
    if is_baggage_octet(c) && c != 0x25 {
      out.write_char(c.unsafe_to_char())
    } else {
      out.write_char('%')
      out.write_char(hex_char(c >> 4))
      out.write_char(hex_char(c & 0x0f))
    }
  }
}

///|
fn hex_char(value : Int32) -> Char {
  if value < 10 {
    (0x30 + value).unsafe_to_char()
  } else {
    (0x41 + value - 10).unsafe_to_char()
  }
}

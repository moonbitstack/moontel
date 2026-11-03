// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Whether `c` is optional whitespace (RFC 7230 §3.2.3): a space or a horizontal
/// tab, the only whitespace a header value may carry between the fields.
fn is_ows(c : Int32) -> Bool {
  c == 0x20 || c == 0x09
}

///|
/// The bounds of `s[start..<end]` without leading or trailing OWS, as a pair of
/// offsets so that a caller can keep pointing into the original string instead of
/// copying the part it wants.
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
/// `text` without the OWS around it. A header value arrives with what the sender
/// put there, and HTTP allows OWS around a field value; the parsers here start
/// after it rather than refusing a header the sender wrote legally.
fn strip_ows(text : StringView) -> StringView {
  let (lo, hi) = trim(text, 0, text.length())
  text.exact_view(start=lo, end=hi)
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How many records the server said it refused, read out of a binary protobuf
/// reply.
///
/// The three success responses are the same shape: a `partial_success` field, and
/// inside it the count for that signal. A body that is not protobuf, or carries no
/// count, answers `None` — "said nothing" and "refused none" are different things,
/// and only the second is good news.
pub fn Reply::rejected_protobuf(self : Reply) -> Int32? {
  protobuf_rejected(self.body[:])
}

///|
fn protobuf_rejected(body : BytesView) -> Int32? {
  let mut at = 0
  let mut found : Int32? = None
  while at < body.length() {
    let (tag, after_tag) = read_varint(body, at)
    at = after_tag
    let field = (tag >> 3).to_int()
    match (tag & 7UL).to_int() {
      2 => {
        let (length, after_length) = read_varint(body, at)
        let end = after_length + length.to_int()
        if field == 1 {
          found = Some(rejected_in(body, after_length, end))
        }
        at = end
      }
      0 => {
        let (_, after_value) = read_varint(body, at)
        at = after_value
      }
      1 => at = at + 8
      5 => at = at + 4
      _ => break
    }
  }
  found
}

///|
/// The rejected count inside a `Export<Signal>PartialSuccess`, or zero when the
/// message carries none: an unset field in proto3 is the zero value, and a reply
/// that says nothing was refused says it by leaving the field out.
fn rejected_in(body : BytesView, start : Int32, end : Int32) -> Int32 {
  let mut at = start
  let mut rejected = 0
  while at < end {
    let (tag, after_tag) = read_varint(body, at)
    at = after_tag
    let field = (tag >> 3).to_int()
    match (tag & 7UL).to_int() {
      0 => {
        let (value, after_value) = read_varint(body, at)
        at = after_value
        if field == 1 {
          rejected = value.to_int()
        }
      }
      2 => {
        let (length, after_length) = read_varint(body, at)
        at = after_length + length.to_int()
      }
      1 => at = at + 8
      5 => at = at + 4
      _ => break
    }
  }
  rejected
}

///|
/// One varint and the offset just past it. A body that ends in the middle of one
/// gives back what it has: a truncated reply is a reply with nothing to say.
fn read_varint(body : BytesView, start : Int32) -> (UInt64, Int32) {
  let mut value = 0UL
  let mut shift = 0
  let mut at = start
  while at < body.length() {
    let byte = body[at].to_int().to_uint64()
    at = at + 1
    value = value | ((byte & 0x7FUL) << shift)
    if byte < 0x80UL {
      break
    }
    shift = shift + 7
  }
  (value, at)
}

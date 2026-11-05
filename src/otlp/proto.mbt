// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A protobuf writer: the wire format and nothing about any schema.
///
/// The three encoders beside this file know the field numbers; this knows varints,
/// tags, length prefixes and the two fixed-width forms. It is hand-written because
/// the messages this library sends are fifteen shapes with numbers that do not
/// change, and a generator would be a build step in every checkout — and a
/// dependency in the package that is supposed to have none.
pub struct ProtoWriter {
  buf : @buffer.Buffer
}

///|
pub fn ProtoWriter::new() -> ProtoWriter {
  { buf: @buffer.Buffer::Buffer(), }
}

///|
/// The bytes written so far, which is one message.
pub fn ProtoWriter::finish(self : ProtoWriter) -> Bytes {
  self.buf.to_bytes()
}

///|
/// A base-128 varint, least significant group first.
fn ProtoWriter::varint(self : ProtoWriter, value : UInt64) -> Unit {
  let mut rest = value
  while rest >= 128UL {
    self.buf.write_byte(((rest.to_uint() & 0x7FU) | 0x80U).to_byte())
    rest = rest >> 7
  }
  self.buf.write_byte(rest.to_uint().to_byte())
}

///|
/// A field's tag: the number and the wire type of what follows.
///
/// Wire types: 0 varint, 1 fixed 64, 2 length-delimited, 5 fixed 32.
fn ProtoWriter::key(self : ProtoWriter, field : Int32, wire : UInt32) -> Unit {
  self.varint((field.to_uint64() << 3) | wire.to_uint64())
}

///|
/// A varint field.
pub fn ProtoWriter::uint(
  self : ProtoWriter,
  field : Int32,
  value : UInt64,
) -> Unit {
  self.key(field, 0U)
  self.varint(value)
}

///|
/// An `int64` field. A negative number is written as ten bytes of two's
/// complement, which is what the wire format asks for and what a reader expects.
pub fn ProtoWriter::int64(
  self : ProtoWriter,
  field : Int32,
  value : Int64,
) -> Unit {
  self.uint(field, value.reinterpret_as_uint64())
}

///|
/// A `uint32` or `uint64` field written from an `Int32` a program already has.
pub fn ProtoWriter::uint32(
  self : ProtoWriter,
  field : Int32,
  value : Int32,
) -> Unit {
  self.uint(field, value.to_uint64())
}

///|
/// A `bool` field.
pub fn ProtoWriter::bool(
  self : ProtoWriter,
  field : Int32,
  value : Bool,
) -> Unit {
  self.uint(field, if value { 1UL } else { 0UL })
}

///|
/// An enum field: proto3 puts the number on the wire, not the name.
pub fn ProtoWriter::enum_code(
  self : ProtoWriter,
  field : Int32,
  code : Int32,
) -> Unit {
  self.uint(field, code.to_uint64())
}

///|
/// A `fixed64` field.
pub fn ProtoWriter::fixed64(
  self : ProtoWriter,
  field : Int32,
  value : UInt64,
) -> Unit {
  self.key(field, 1U)
  self.fixed64_raw(value)
}

///|
fn ProtoWriter::fixed64_raw(self : ProtoWriter, value : UInt64) -> Unit {
  let mut rest = value
  for _ in 0..<8 {
    self.buf.write_byte((rest.to_uint() & 0xFFU).to_byte())
    rest = rest >> 8
  }
}

///|
/// A `double` field: eight bytes of IEEE 754, little endian.
pub fn ProtoWriter::double(
  self : ProtoWriter,
  field : Int32,
  value : Double,
) -> Unit {
  self.fixed64(field, value.reinterpret_as_uint64())
}

///|
/// A `fixed32` field: four bytes, little endian.
pub fn ProtoWriter::fixed32(
  self : ProtoWriter,
  field : Int32,
  value : UInt32,
) -> Unit {
  self.key(field, 5U)
  let mut rest = value
  for _ in 0..<4 {
    self.buf.write_byte((rest & 0xFFU).to_byte())
    rest = rest >> 8
  }
}

///|
/// A `bytes` field: a length, then the bytes.
pub fn ProtoWriter::bytes(
  self : ProtoWriter,
  field : Int32,
  value : BytesView,
) -> Unit {
  self.key(field, 2U)
  self.varint(value.length().to_uint64())
  self.buf.write_bytesview(value)
}

///|
/// A `string` field: UTF-8, length-prefixed like bytes.
pub fn ProtoWriter::string(
  self : ProtoWriter,
  field : Int32,
  value : String,
) -> Unit {
  self.bytes(field, @utf8.encode(value)[:])
}

///|
/// A nested message: its bytes, with their length in front.
///
/// The body is built in a writer of its own, because a length has to be known
/// before the bytes it counts are written. Nesting is shallow here — a span inside
/// a scope inside a resource — so the copy costs nothing worth avoiding.
pub fn ProtoWriter::message(
  self : ProtoWriter,
  field : Int32,
  body : ProtoWriter,
) -> Unit {
  let bytes = body.finish()
  self.bytes(field, bytes[:])
}

///|
/// A repeated `double`, packed: one length-delimited field holding all of them.
/// Proto3 packs repeated numerics by default, and a packed field is what a reader
/// of the schema expects.
pub fn ProtoWriter::packed_doubles(
  self : ProtoWriter,
  field : Int32,
  values : Array[Double],
) -> Unit {
  if values.is_empty() {
    return
  }
  let inner = ProtoWriter::new()
  for value in values {
    inner.fixed64_raw(value.reinterpret_as_uint64())
  }
  self.message(field, inner)
}

///|
/// A repeated `fixed64`, packed.
pub fn ProtoWriter::packed_fixed64(
  self : ProtoWriter,
  field : Int32,
  values : Array[UInt64],
) -> Unit {
  if values.is_empty() {
    return
  }
  let inner = ProtoWriter::new()
  for value in values {
    inner.fixed64_raw(value)
  }
  self.message(field, inner)
}

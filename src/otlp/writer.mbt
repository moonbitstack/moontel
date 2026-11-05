// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A JSON writer for one OTLP request body.
///
/// It writes text into a `StringBuilder` rather than building a tree of values,
/// because a batch of five hundred spans is large enough that the tree would cost
/// more than the request it describes, and because the OpenTelemetry JSON mapping
/// has rules a general-purpose encoder does not follow: 64-bit integers are
/// decimal strings, enum fields are integers, and names are lowerCamelCase.
///
/// A writer keeps two things per open container: whether it has written a member
/// yet, and whether a name has just been written and its value is due.
priv struct JsonWriter {
  out : StringBuilder
  started : Array[Bool]
  pending : Array[Bool]
}

///|
fn JsonWriter::new() -> JsonWriter {
  { out: StringBuilder(), started: [], pending: [], }
}

///|
fn JsonWriter::text(self : JsonWriter) -> String {
  self.out.to_string()
}

///|
/// A comma if this container already has a member.
fn JsonWriter::separate(self : JsonWriter) -> Unit {
  let n = self.started.length()
  if n > 0 {
    if self.started[n - 1] {
      self.out.write_char(',')
    } else {
      self.started[n - 1] = true
    }
  }
}

///|
/// Called before anything that is a member value: a name just written swallows the
/// separator it would otherwise take.
fn JsonWriter::slot(self : JsonWriter) -> Unit {
  let n = self.pending.length()
  if n > 0 && self.pending[n - 1] {
    self.pending[n - 1] = false
  } else {
    self.separate()
  }
}

///|
fn JsonWriter::open_object(self : JsonWriter) -> Unit {
  self.slot()
  self.out.write_char('{')
  self.started.push(false)
  self.pending.push(false)
}

///|
fn JsonWriter::close_object(self : JsonWriter) -> Unit {
  self.started.pop() |> ignore
  self.pending.pop() |> ignore
  self.out.write_char('}')
}

///|
fn JsonWriter::open_array(self : JsonWriter) -> Unit {
  self.slot()
  self.out.write_char('[')
  self.started.push(false)
  self.pending.push(false)
}

///|
fn JsonWriter::close_array(self : JsonWriter) -> Unit {
  self.started.pop() |> ignore
  self.pending.pop() |> ignore
  self.out.write_char(']')
}

///|
fn JsonWriter::name(self : JsonWriter, name : String) -> Unit {
  self.separate()
  self.write_escaped(name)
  self.out.write_char(':')
  let n = self.pending.length()
  self.pending[n - 1] = true
}

///|
fn JsonWriter::string(self : JsonWriter, value : String) -> Unit {
  self.slot()
  self.write_escaped(value)
}

///|
/// A number that is already text, such as an enum's integer or a double this
/// library has formatted itself.
fn JsonWriter::raw(self : JsonWriter, value : String) -> Unit {
  self.slot()
  self.out.write_string(value)
}

///|
/// A 64-bit integer. Protobuf's JSON mapping writes one as a decimal string, and
/// every timestamp in OTLP is such a field: a nanosecond value does not fit the
/// 53 bits a JSON number survives.
fn JsonWriter::int64(self : JsonWriter, value : Int64) -> Unit {
  self.slot()
  self.out.write_char('"')
  self.out.write_string(value.to_string())
  self.out.write_char('"')
}

///|
/// A double. A value JSON cannot carry — an infinity or a NaN — is written as
/// zero: a batch is worth more than the one point a broken producer contributed,
/// and a request with `Infinity` in it is refused by every receiver.
fn JsonWriter::double(self : JsonWriter, value : Double) -> Unit {
  if !(value >= -1.7976931348623157e308) || !(value <= 1.7976931348623157e308) {
    self.raw("0")
  } else {
    self.raw(value.to_string())
  }
}

///|
fn JsonWriter::boolean(self : JsonWriter, value : Bool) -> Unit {
  self.raw(if value { "true" } else { "false" })
}

///|
/// A string with the escapes JSON requires: quote, reverse solidus and the control
/// characters. Everything else is written as it stands, which keeps non-ASCII text
/// readable in a request body instead of turning it into `\u` sequences.
fn JsonWriter::write_escaped(self : JsonWriter, value : String) -> Unit {
  self.out.write_char('"')
  for c in value {
    let code = c.to_int()
    if code == 0x22 {
      self.out.write_string("\\\"")
    } else if code == 0x5c {
      self.out.write_string("\\\\")
    } else if code == 0x0a {
      self.out.write_string("\\n")
    } else if code == 0x0d {
      self.out.write_string("\\r")
    } else if code == 0x09 {
      self.out.write_string("\\t")
    } else if code == 0x08 {
      self.out.write_string("\\b")
    } else if code == 0x0c {
      self.out.write_string("\\f")
    } else if code < 0x20 {
      self.out.write_string("\\u00")
      self.out.write_char(hex_digit(code >> 4))
      self.out.write_char(hex_digit(code & 0x0f))
    } else {
      self.out.write_char(c)
    }
  }
  self.out.write_char('"')
}

///|
fn hex_digit(value : Int32) -> Char {
  if value < 10 {
    (0x30 + value).unsafe_to_char()
  } else {
    (0x61 + value - 10).unsafe_to_char()
  }
}

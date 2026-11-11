// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A JSON tree under construction, for one OTLP request body.
///
/// The encoders write members in the order the protocol lists them and the tree
/// keeps that order, so a body reads like the specification's own field table and
/// two runs of the same program produce the same bytes. The text itself is written
/// by `moonjson`, which is what keeps this package from owning a second JSON
/// writer: escapes, number formatting and the strict grammar are the family
/// library's job.
///
/// The OpenTelemetry JSON mapping has rules a general-purpose encoder does not
/// follow — 64-bit integers are decimal strings, enum fields are integers, names
/// are lowerCamelCase — so those are decided here, member by member.
priv enum Container {
  /// The values of an array, in the order they were written.
  Listing(Array[Json])
  /// The members of an object, in order, and the name whose value is due.
  Members(Array[(String, Json)], String?)
}

///|
priv struct JsonWriter {
  stack : Array[Container]
  mut root : Json?
}

///|
fn JsonWriter::new() -> JsonWriter {
  { stack: [], root: None, }
}

///|
fn JsonWriter::text(self : JsonWriter) -> String {
  let tree = match self.root {
    Some(tree) => tree
    None => Json::null()
  }
  @moonjson.dumps(tree)
}

///|
/// Put a finished value where the open container wants it.
fn JsonWriter::emit(self : JsonWriter, value : Json) -> Unit {
  let depth = self.stack.length()
  if depth == 0 {
    self.root = Some(value)
    return
  }
  let top = self.stack[depth - 1]
  match top {
    Listing(items) => items.push(value)
    Members(members, waiting) =>
      match waiting {
        Some(name) => {
          members.push((name, value))
          self.stack[depth - 1] = Members(members, None)
        }
        // Every value inside an object is written after its name; a value with
        // none would be a body no reader could parse, so it is a mistake here
        // rather than on the wire.
        None => abort("a JSON member was written without a name")
      }
  }
}

///|
fn JsonWriter::open_object(self : JsonWriter) -> Unit {
  self.stack.push(Members([], None))
}

///|
fn JsonWriter::close_object(self : JsonWriter) -> Unit {
  let top = self.pop()
  match top {
    Members(members, _) => self.emit(object_of(members))
    Listing(_) => abort("an array was closed as an object")
  }
}

///|
fn JsonWriter::open_array(self : JsonWriter) -> Unit {
  self.stack.push(Listing([]))
}

///|
fn JsonWriter::close_array(self : JsonWriter) -> Unit {
  let top = self.pop()
  match top {
    Listing(items) => self.emit(Json::array(items))
    Members(_, _) => abort("an object was closed as an array")
  }
}

///|
fn JsonWriter::pop(self : JsonWriter) -> Container {
  match self.stack.pop() {
    Some(top) => top
    None => abort("a container was closed that was never opened")
  }
}

///|
fn JsonWriter::name(self : JsonWriter, name : String) -> Unit {
  let depth = self.stack.length()
  if depth == 0 {
    abort("a member name was written outside an object")
  }
  match self.stack[depth - 1] {
    Members(members, _) => self.stack[depth - 1] = Members(members, Some(name))
    Listing(_) => abort("a member name was written inside an array")
  }
}

///|
fn JsonWriter::string(self : JsonWriter, value : String) -> Unit {
  self.emit(Json::string(value))
}

///|
/// A number that is already text, such as an enum's integer.
fn JsonWriter::raw(self : JsonWriter, value : String) -> Unit {
  self.emit(Json::number(0.0, repr=value))
}

///|
/// A 64-bit integer. Protobuf's JSON mapping writes one as a decimal string, and
/// every timestamp in OTLP is such a field: a nanosecond value does not fit the
/// 53 bits a JSON number survives.
fn JsonWriter::int64(self : JsonWriter, value : Int64) -> Unit {
  self.emit(Json::string(value.to_string()))
}

///|
/// A double. A value JSON cannot carry — an infinity or a NaN — is written as
/// zero: a batch is worth more than the one point a broken producer contributed,
/// and a request with `Infinity` in it is refused by every receiver.
fn JsonWriter::double(self : JsonWriter, value : Double) -> Unit {
  if value >= -1.7976931348623157e308 && value <= 1.7976931348623157e308 {
    self.emit(Json::number(value))
  } else {
    self.emit(Json::number(0.0))
  }
}

///|
fn JsonWriter::boolean(self : JsonWriter, value : Bool) -> Unit {
  self.emit(Json::boolean(value))
}

///|
/// An object from its members, in the order they were written.
fn object_of(members : Array[(String, Json)]) -> Json {
  let fields : Map[String, Json] = Map([])
  for entry in members {
    fields.set(entry.0, entry.1)
  }
  Json::object(fields)
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One attribute value as an OTLP `AnyValue`, which is a `oneof` of the seven
/// shapes OpenTelemetry allows: the field number is the type, so a reader cannot
/// mistake `200` for text.
///
/// An array keeps the type of its elements, because OpenTelemetry requires an array
/// attribute to be homogeneous — which is why `Value` has one array variant per
/// element type rather than one array of values.
fn any_value(value : @trace.Value) -> ProtoWriter {
  let w = ProtoWriter::new()
  match value {
    @trace.Str(v) => w.string(1, v)
    @trace.Bool(v) => w.bool(2, v)
    @trace.Int(v) => w.int64(3, v)
    @trace.Double(v) => w.double(4, v)
    @trace.Bools(values) =>
      w.message(5, array_value(values.map(v => @trace.Bool(v))))
    @trace.Ints(values) =>
      w.message(5, array_value(values.map(v => @trace.Int(v))))
    @trace.Doubles(values) =>
      w.message(5, array_value(values.map(v => @trace.Double(v))))
    @trace.Strs(values) =>
      w.message(5, array_value(values.map(v => @trace.Str(v))))
  }
  w
}

///|
/// The `ArrayValue` of an attribute whose elements are all of one type.
fn array_value(values : Array[@trace.Value]) -> ProtoWriter {
  let w = ProtoWriter::new()
  for value in values {
    w.message(1, any_value(value))
  }
  w
}

///|
/// Repeated `KeyValue` into `field`: a key, and a value tagged with its type.
fn write_key_values(
  w : ProtoWriter,
  field : Int32,
  attributes : Array[(String, @trace.Value)],
) -> Unit {
  for attribute in attributes {
    let pair = ProtoWriter::new()
    pair.string(1, attribute.0)
    pair.message(2, any_value(attribute.1))
    w.message(field, pair)
  }
}

///|
/// The `Resource` message: the attribute set that says what produced this telemetry.
fn resource_message(resource : Resource) -> ProtoWriter {
  let w = ProtoWriter::new()
  write_key_values(w, 1, resource.attributes)
  w
}

///|
/// The `InstrumentationScope` message: which library in the program produced this.
fn scope_message(scope : Scope) -> ProtoWriter {
  let w = ProtoWriter::new()
  w.string(1, scope.name)
  match scope.version {
    Some(version) => w.string(2, version)
    None => ()
  }
  write_key_values(w, 3, scope.attributes)
  w
}

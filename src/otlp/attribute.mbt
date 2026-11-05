// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One attribute, as an OTLP `KeyValue`: a name, and a value tagged with its type.
///
/// The tag is what makes an integer stay an integer across the wire; a receiver
/// that had to guess would show `200` as text on one dashboard and as a number on
/// another.
fn write_attributes(
  w : JsonWriter,
  attributes : Array[(String, @trace.Value)],
) -> Unit {
  w.open_array()
  for attribute in attributes {
    w.open_object()
    w.name("key")
    w.string(attribute.0)
    w.name("value")
    write_any_value(w, attribute.1)
    w.close_object()
  }
  w.close_array()
}

///|
/// One attribute value, tagged with the field name of its type.
///
/// An array keeps the tag of its elements: OpenTelemetry requires an array
/// attribute to be homogeneous, which is why the value type has one variant per
/// element type rather than one array of values.
fn write_any_value(w : JsonWriter, value : @trace.Value) -> Unit {
  w.open_object()
  match value {
    @trace.Bool(v) => {
      w.name("boolValue")
      w.boolean(v)
    }
    @trace.Int(v) => {
      w.name("intValue")
      w.int64(v)
    }
    @trace.Double(v) => {
      w.name("doubleValue")
      w.double(v)
    }
    @trace.Str(v) => {
      w.name("stringValue")
      w.string(v)
    }
    @trace.Bools(values) => {
      w.name("arrayValue")
      w.open_object()
      w.name("values")
      w.open_array()
      for v in values {
        w.open_object()
        w.name("boolValue")
        w.boolean(v)
        w.close_object()
      }
      w.close_array()
      w.close_object()
    }
    @trace.Ints(values) => {
      w.name("arrayValue")
      w.open_object()
      w.name("values")
      w.open_array()
      for v in values {
        w.open_object()
        w.name("intValue")
        w.int64(v)
        w.close_object()
      }
      w.close_array()
      w.close_object()
    }
    @trace.Doubles(values) => {
      w.name("arrayValue")
      w.open_object()
      w.name("values")
      w.open_array()
      for v in values {
        w.open_object()
        w.name("doubleValue")
        w.double(v)
        w.close_object()
      }
      w.close_array()
      w.close_object()
    }
    @trace.Strs(values) => {
      w.name("arrayValue")
      w.open_object()
      w.name("values")
      w.open_array()
      for v in values {
        w.open_object()
        w.name("stringValue")
        w.string(v)
        w.close_object()
      }
      w.close_array()
      w.close_object()
    }
  }
  w.close_object()
}

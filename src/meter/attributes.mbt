// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The attributes a measurement carries, kept as a set rather than a list.
///
/// A series is identified by its attribute set, so two writes that name the same
/// facts in a different order must land in one series. Keys are sorted, a key
/// written twice keeps the last value, and the identity string is length-prefixed
/// so a key containing a separator cannot make two different sets collide.
///
/// Dots in a key are ordinary characters: `gen_ai.request.model` travels
/// unchanged, as the semantic conventions spell it. Nothing here rewrites a name
/// into the underscores an exposition format would need.
#derive(Eq, Debug)
pub(all) struct Attributes {
  entries : Array[(String, @trace.Value)]
}

///|
pub extend Attributes with Eq::{equal, not_equal}

///|
pub extend Attributes with Debug::{to_repr}

///|
/// The empty attribute set: the series with no dimensions.
pub let empty_attributes : Attributes = { entries: [], }

///|
/// An attribute set built from these entries.
pub fn Attributes::new(
  entries~ : Array[(String, @trace.Value)] = [],
) -> Attributes {
  normalize(entries)
}

///|
/// The same set with `key` set to `value`, replacing an earlier value under that
/// key. Returns a new value, so a set a caller shares with several instruments
/// cannot change underneath one of them.
pub fn Attributes::with_attribute(
  self : Attributes,
  key : String,
  value : @trace.Value,
) -> Attributes {
  let entries = self.entries.copy()
  entries.push((key, value))
  normalize(entries)
}

///|
/// The value under `key`.
pub fn Attributes::get(self : Attributes, key : String) -> @trace.Value? {
  for entry in self.entries {
    if entry.0 == key {
      return Some(entry.1)
    }
  }
  None
}

///|
/// The entries, sorted by key.
pub fn Attributes::to_array(self : Attributes) -> Array[(String, @trace.Value)] {
  self.entries.copy()
}

///|
/// How many attributes the set holds.
pub fn Attributes::len(self : Attributes) -> Int32 {
  self.entries.length()
}

///|
/// A string that is equal for equal attribute sets and different otherwise.
///
/// Used as the key of a series, so it has to be unambiguous: each key and value
/// carries its length, and the type of the value is part of the text — a string
/// `"12"` and the integer `12` are two different dimensions.
pub fn Attributes::identity(self : Attributes) -> String {
  let out = StringBuilder()
  for entry in self.entries {
    let key = entry.0
    let value = value_key(entry.1)
    out.write_string(key.length().to_string())
    out.write_char(':')
    out.write_string(key)
    out.write_char('=')
    out.write_string(value.length().to_string())
    out.write_char(':')
    out.write_string(value)
  }
  out.to_string()
}

///|
/// The attribute keys the GenAI metric conventions attach to a client operation.
/// A dashboard matches on these spellings; writing them by hand is how a near
/// miss becomes a value no dashboard shows.
pub let gen_ai_metric_keys : Array[String] = [
  @semconv.gen_ai_provider_name, @semconv.gen_ai_operation_name, @semconv.gen_ai_request_model,
  @semconv.gen_ai_response_model, @semconv.gen_ai_agent_name, @semconv.gen_ai_conversation_id,
]

///|
/// The attribute group for one GenAI client operation.
///
/// The three required names come from the metric's attribute group; the optional
/// ones are the parts a caller knows only after the response arrives. Every key
/// is a constant from `semconv`, so a rename upstream moves the pin and the
/// generated constants rather than a string in instrumented code.
pub fn gen_ai_client_attributes(
  provider~ : String,
  operation~ : String,
  request_model~ : String,
  response_model? : String,
  agent_name? : String,
  conversation_id? : String,
) -> Attributes {
  let entries : Array[(String, @trace.Value)] = [
    (@semconv.gen_ai_provider_name, @trace.Str(provider)),
    (@semconv.gen_ai_operation_name, @trace.Str(operation)),
    (@semconv.gen_ai_request_model, @trace.Str(request_model)),
  ]
  match response_model {
    Some(value) =>
      entries.push((@semconv.gen_ai_response_model, @trace.Str(value)))
    None => ()
  }
  match agent_name {
    Some(value) => entries.push((@semconv.gen_ai_agent_name, @trace.Str(value)))
    None => ()
  }
  match conversation_id {
    Some(value) =>
      entries.push((@semconv.gen_ai_conversation_id, @trace.Str(value)))
    None => ()
  }
  Attributes::new(entries~)
}

// ------------------------------------------------------------------ internals

///|
/// Sort by key, keep the last value under a duplicate key. Selection sort is
/// enough for the 128 attributes a set can hold, and it needs no comparator from
/// outside this package.
fn normalize(entries : Array[(String, @trace.Value)]) -> Attributes {
  let sorted = entries.copy()
  for i in 0..<sorted.length() {
    let mut lowest = i
    for j in (i + 1)..<sorted.length() {
      if key_less(sorted[j].0, sorted[lowest].0) {
        lowest = j
      }
    }
    if lowest != i {
      let hold = sorted[i]
      sorted[i] = sorted[lowest]
      sorted[lowest] = hold
    }
  }
  let out : Array[(String, @trace.Value)] = []
  for i in 0..<sorted.length() {
    if i + 1 < sorted.length() && sorted[i].0 == sorted[i + 1].0 {
      continue
    }
    out.push(sorted[i])
  }
  { entries: out, }
}

///|
/// Lexicographic order over code points. A series key has to be the same on
/// every backend, so it cannot depend on how one runtime orders strings that
/// differ in length.
fn key_less(left : String, right : String) -> Bool {
  let a = codes(left)
  let b = codes(right)
  let shared = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<shared {
    if a[i] != b[i] {
      return a[i] < b[i]
    }
  }
  a.length() < b.length()
}

///|
fn codes(text : String) -> Array[Int32] {
  let out : Array[Int32] = []
  for c in text {
    out.push(c.to_int())
  }
  out
}

///|
fn value_key(value : @trace.Value) -> String {
  match value {
    @trace.Bool(v) => "b\{v}"
    @trace.Int(v) => "i\{v}"
    @trace.Double(v) => "d\{v}"
    @trace.Str(v) => "s\{v}"
    @trace.Bools(vs) => typed_array("ba", vs.length(), i => "\{vs[i]}")
    @trace.Ints(vs) => typed_array("ia", vs.length(), i => "\{vs[i]}")
    @trace.Doubles(vs) => typed_array("da", vs.length(), i => "\{vs[i]}")
    @trace.Strs(vs) => typed_array("sa", vs.length(), i => vs[i])
  }
}

///|
fn typed_array(tag : String, length : Int32, at : (Int32) -> String) -> String {
  let out = StringBuilder()
  out.write_string(tag)
  for i in 0..<length {
    let text = at(i)
    out.write_string(text.length().to_string())
    out.write_char(':')
    out.write_string(text)
  }
  out.to_string()
}

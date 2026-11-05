// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What produced the telemetry: the service, the host, the deployment.
///
/// Every signal carries the same resource, because it is what makes a span, a
/// metric point and a log line from one process recognisable as coming from one
/// place. The specification requires `service.name` to be present, so the default
/// here is the one it names for a program that never set one.
#derive(Eq, Debug)
pub(all) struct Resource {
  attributes : Array[(String, @trace.Value)]
}

///|
pub extend Resource with Eq::{equal, not_equal}

///|
pub extend Resource with Debug::{to_repr}

///|
/// The resource a program that has not described itself exports under:
/// `service.name` is `unknown_service`, which is what the specification asks for
/// rather than a guess at the binary's name.
pub let unknown_service : Resource = {
  attributes: [("service.name", @trace.Str("unknown_service"))],
}

///|
/// A resource with exactly these attributes.
pub fn Resource::new(attributes~ : Array[(String, @trace.Value)]) -> Resource {
  { attributes, }
}

///|
/// A resource with `service.name` set to `name` and nothing else.
pub fn Resource::of_service(name : String) -> Resource {
  { attributes: [("service.name", @trace.Str(name))], }
}

///|
/// The same resource with one more attribute, replacing a value under the same key.
pub fn Resource::with_attribute(
  self : Resource,
  key : String,
  value : @trace.Value,
) -> Resource {
  { attributes: upsert(self.attributes, key, value), }
}

///|
/// The value under `key`, or `None` when the resource does not carry it.
pub fn Resource::get(self : Resource, key : String) -> @trace.Value? {
  for attribute in self.attributes {
    if attribute.0 == key {
      return Some(attribute.1)
    }
  }
  None
}

///|
/// The instrumentation scope: which library in the program produced the telemetry,
/// and at which version. A backend groups by it, which is how a reader can tell
/// the spans this library made from the ones a framework made.
#derive(Eq, Debug)
pub(all) struct Scope {
  name : String
  version : String?
  attributes : Array[(String, @trace.Value)]
}

///|
pub extend Scope with Eq::{equal, not_equal}

///|
pub extend Scope with Debug::{to_repr}

///|
/// The scope this library exports under.
pub let moonbit_scope : Scope = {
  name: "moonbitstack/moontel",
  version: None,
  attributes: [],
}

///|
/// A scope with this name, and a version when the caller knows one.
pub fn Scope::new(
  name~ : String,
  version? : String,
  attributes~ : Array[(String, @trace.Value)] = [],
) -> Scope {
  { name, version, attributes, }
}

///|
fn write_resource(w : JsonWriter, resource : Resource) -> Unit {
  w.open_object()
  if !resource.attributes.is_empty() {
    w.name("attributes")
    write_attributes(w, resource.attributes)
  }
  w.close_object()
}

///|
fn write_scope(w : JsonWriter, scope : Scope) -> Unit {
  w.open_object()
  w.name("name")
  w.string(scope.name)
  match scope.version {
    Some(version) => {
      w.name("version")
      w.string(version)
    }
    None => ()
  }
  if !scope.attributes.is_empty() {
    w.name("attributes")
    write_attributes(w, scope.attributes)
  }
  w.close_object()
}

///|
/// `attributes` with `key` set to `value`, in the position the key first held.
fn upsert(
  attributes : Array[(String, @trace.Value)],
  key : String,
  value : @trace.Value,
) -> Array[(String, @trace.Value)] {
  let out : Array[(String, @trace.Value)] = []
  let mut replaced = false
  for attribute in attributes {
    if attribute.0 == key {
      out.push((key, value))
      replaced = true
    } else {
      out.push(attribute)
    }
  }
  if !replaced {
    out.push((key, value))
  }
  out
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How much one span collects.
///
/// The defaults are OpenTelemetry's: 128 attributes, 128 events, 128 links, 128
/// attributes on an event, and no limit on the length of a value. They exist to
/// keep instrumentation that loops over user data from taking the process down
/// with it, so the counts are per span and fixed when the span starts.
#derive(Eq, Debug)
pub(all) struct Limits {
  attributes : Int32
  events : Int32
  links : Int32
  attributes_per_event : Int32
  /// `None` keeps values of any length. A number cuts every string attribute to
  /// that many characters, counting each as one.
  attribute_value_length : Int32?
}

///|
pub extend Limits with Eq::{equal, not_equal}

///|
pub extend Limits with Debug::{to_repr}

///|
/// The OpenTelemetry defaults, from the trace SDK specification's span limits
/// table.
pub let trace_limits : Limits = {
  attributes: 128,
  events: 128,
  links: 128,
  attributes_per_event: 128,
  attribute_value_length: None,
}

///|
/// The same defaults, with any of them changed.
pub fn Limits::new(
  attributes~ : Int32 = trace_limits.attributes,
  events~ : Int32 = trace_limits.events,
  links~ : Int32 = trace_limits.links,
  attributes_per_event~ : Int32 = trace_limits.attributes_per_event,
  attribute_value_length~ : Int32? = trace_limits.attribute_value_length,
) -> Limits {
  { attributes, events, links, attributes_per_event, attribute_value_length, }
}

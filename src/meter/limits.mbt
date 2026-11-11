// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Which of the four synchronous instruments a name belongs to.
///
/// The OTLP exporter has its own kinds because a reader sees a sum, a gauge, a
/// histogram or a summary; this one says what the producer is allowed to do. A
/// counter and an up-down counter are both sums on the wire, but only one of them
/// may go down.
#derive(Eq, Debug)
pub(all) enum InstrumentKind {
  Counter
  UpDownCounter
  Histogram
  Gauge
}

///|
pub extend InstrumentKind with Eq::{equal, not_equal}

///|
pub extend InstrumentKind with Debug::{to_repr}

///|
/// How much one instrument keeps.
///
/// The attribute limits are OpenTelemetry's own: 128 attributes on a point, and
/// no limit on the length of a string value. `series` is the SDK's default
/// cardinality limit of 2000 per instrument, and `exemplars` is how many sampled
/// traces are kept beside a series. All four exist so a loop over user data cannot
/// make one instrument unbounded.
#derive(Eq, Debug)
pub(all) struct MeterLimits {
  attributes : Int32
  attribute_value_length : Int32?
  series : Int32
  exemplars : Int32
}

///|
pub extend MeterLimits with Eq::{equal, not_equal}

///|
pub extend MeterLimits with Debug::{to_repr}

///|
/// The OpenTelemetry defaults, from the metrics SDK specification's attribute
/// limits and cardinality limit sections.
pub let meter_limits : MeterLimits = {
  attributes: 128,
  attribute_value_length: None,
  series: 2000,
  exemplars: 1,
}

///|
/// The same limits, with any of them changed.
pub fn MeterLimits::new(
  attributes~ : Int32 = meter_limits.attributes,
  attribute_value_length~ : Int32? = meter_limits.attribute_value_length,
  series~ : Int32 = meter_limits.series,
  exemplars~ : Int32 = meter_limits.exemplars,
) -> MeterLimits {
  { attributes, attribute_value_length, series, exemplars, }
}

///|
/// The longest instrument name the metrics specification allows.
pub let instrument_name_limit : Int32 = 255

///|
/// Why a name or a bucket list was refused.
#derive(Eq, Debug)
pub(all) suberror Refused {
  /// The empty string is not a name.
  EmptyName
  /// A name that does not start with an ASCII letter, or carries a character the
  /// specification does not allow. Dots, slashes, hyphens and underscores are
  /// allowed, which is what a semantic convention name needs.
  InvalidName(name~ : String)
  /// A name longer than `instrument_name_limit`.
  LongName(name~ : String, got~ : Int32, limit~ : Int32)
  /// A bucket boundary that is not finite, or is not greater than the one before
  /// it, at this position in the list.
  Bounds(name~ : String, at~ : Int32)
  /// A name already registered as a different kind of instrument.
  Conflict(name~ : String, got~ : InstrumentKind, want~ : InstrumentKind)
}

///|
pub extend Refused with Eq::{equal, not_equal}

///|
pub extend Refused with Debug::{to_repr}

///|
/// Whether `name` is an instrument name the specification allows.
pub fn is_valid_name(name : String) -> Bool {
  let length = name.length()
  if length == 0 || length > instrument_name_limit {
    return false
  }
  let mut first = true
  for c in name {
    let code = c.to_int()
    let letter = (code >= 0x41 && code <= 0x5a) ||
      (code >= 0x61 && code <= 0x7a)
    let digit = code >= 0x30 && code <= 0x39
    let separator = code == 0x2e || code == 0x2d || code == 0x5f || code == 0x2f
    if first {
      if !letter {
        return false
      }
      first = false
    } else if !(letter || digit || separator) {
      return false
    }
  }
  true
}

///|
fn validate_name(name : String) -> Unit raise Refused {
  if name.length() == 0 {
    raise Refused::EmptyName
  }
  if name.length() > instrument_name_limit {
    raise Refused::LongName(
      name~,
      got=name.length(),
      limit=instrument_name_limit,
    )
  }
  if !is_valid_name(name) {
    raise Refused::InvalidName(name~)
  }
}

///|
/// Bucket boundaries have to be finite and strictly increasing: a NaN or a
/// repeated boundary makes the bucket a measurement belongs to ambiguous.
fn validate_bounds(bounds : Array[Double], name : String) -> Unit raise Refused {
  if bounds.length() == 0 {
    raise Refused::Bounds(name~, at=0)
  }
  for i in 0..<bounds.length() {
    if !finite(bounds[i]) || (i > 0 && !(bounds[i] > bounds[i - 1])) {
      raise Refused::Bounds(name~, at=i)
    }
  }
}

///|
fn finite(value : Double) -> Bool {
  value >= -1.7976931348623157e308 && value <= 1.7976931348623157e308
}

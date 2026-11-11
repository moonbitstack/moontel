// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How a stream turns measurements into a point.
///
/// The aggregation is chosen by the instrument unless a view overrides it, which is
/// what lets one program export a duration both as an explicit-bucket histogram and
/// as an exponential one without recording it twice.
#derive(Eq, Debug)
pub(all) enum Aggregation {
  /// A running total. A monotonic sum only grows; a non-monotonic one takes either
  /// sign.
  Sum
  /// The most recent measurement.
  LastValue
  /// A distribution over these boundaries, the last count being everything above
  /// the last bound.
  ExplicitBuckets(bounds~ : Array[Double])
  /// A base-2 distribution whose buckets split and merge so that no more than
  /// `max_buckets` are in use. `scale` is where it starts: the finer the scale, the
  /// more buckets a given range of measurements takes.
  ExponentialBuckets(scale~ : Int32, max_buckets~ : Int32)
  /// Nothing: the instrument is registered and its measurements are thrown away.
  Drop
}

///|
pub extend Aggregation with Eq::{equal, not_equal}

///|
pub extend Aggregation with Debug::{to_repr}

///|
/// What a view does to the instruments it selects.
///
/// A view is how a program decides what a metric looks like without touching the
/// call sites: the name on the wire, the description, which attributes survive, and
/// how the measurements are aggregated. One instrument can be seen through several
/// views, and each view that is not `Drop` is a stream of its own on the wire.
///
/// `instrument` is the instrument's name, or `*` for every instrument. Matching is
/// case-insensitive, as instrument names are.
#derive(Eq, Debug)
pub(all) struct View {
  instrument : String
  kind : InstrumentKind?
  name : String?
  description : String?
  attribute_keys : Array[String]?
  aggregation : Aggregation?
}

///|
pub extend View with Eq::{equal, not_equal}

///|
pub extend View with Debug::{to_repr}

///|
/// A view over one instrument, or over every instrument.
///
/// `kind` widens the selection to a type of instrument, so one view can catch the
/// four sums a library registers without naming each. `attribute_keys` is an
/// allowlist: the keys named survive, the rest are dropped before the series are
/// formed, which is how a program keeps a high-cardinality key such as a request id
/// off the wire. `Some([])` keeps no attribute at all.
pub fn View::new(
  instrument~ : String = "*",
  kind? : InstrumentKind,
  name? : String,
  description? : String,
  attribute_keys? : Array[String],
  aggregation? : Aggregation,
) -> View {
  { instrument, kind, name, description, attribute_keys, aggregation, }
}

///|
/// Whether this view selects an instrument of that name and type.
fn View::selects(self : View, name : String, kind : InstrumentKind) -> Bool {
  let named = self.instrument == "*" ||
    self.instrument.to_lower() == name.to_lower()
  if !named {
    return false
  }
  match self.kind {
    Some(wanted) => wanted == kind
    None => true
  }
}

///|
/// The default aggregation of an instrument kind, which is what a stream uses when
/// no view says otherwise.
fn default_aggregation(
  kind : InstrumentKind,
  bounds : Array[Double],
  max_buckets : Int32,
) -> Aggregation {
  match kind {
    Counter | UpDownCounter | ObservableCounter | ObservableUpDownCounter => Sum
    Gauge | ObservableGauge => LastValue
    Histogram => ExplicitBuckets(bounds~)
    ExponentialHistogram =>
      ExponentialBuckets(scale=max_exponential_scale, max_buckets~)
  }
}

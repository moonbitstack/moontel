// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The default explicit bucket boundaries of the OpenTelemetry Metrics SDK:
/// `[0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]`.
///
/// Source: the Metrics SDK specification, "Explicit Bucket Histogram
/// Aggregation", the `Boundaries` row of the aggregation's parameter table:
/// https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md#explicit-bucket-histogram-aggregation
///
/// The specification gives the intervals as `(-Inf, 0], (0, 5], (5, 10], ...`
/// up to `(10000, +Inf)`, notes that the values were chosen from the default
/// buckets of the Prometheus clients, and says an SDK SHOULD use them when the
/// caller does not supply boundaries. These are plain numbers: the unit is the
/// instrument's own, so a histogram registered with `s` measures seconds and one
/// registered with `ms` measures milliseconds.
pub let default_buckets : Array[Double] = [
  0.0, 5.0, 10.0, 25.0, 50.0, 75.0, 100.0, 250.0, 500.0, 750.0, 1000.0, 2500.0, 5000.0,
  7500.0, 10000.0,
]

///|
/// Which bucket `value` falls into.
///
/// A bucket is inclusive of its upper bound, so the answer is the first boundary
/// greater than or equal to the measurement. When none is, the answer is one past
/// the last boundary: OTLP wants one more count than there are bounds, and that
/// last count is the `+Inf` bucket.
pub fn bucket_index(bounds : Array[Double], value : Double) -> Int32 {
  for i in 0..<bounds.length() {
    if value <= bounds[i] {
      return i
    }
  }
  bounds.length()
}

///|
/// An empty set of bucket counts: one per finite boundary, plus the overflow.
pub fn empty_counts(bounds : Array[Double]) -> Array[Int64] {
  let counts : Array[Int64] = []
  for _ in 0..<(bounds.length() + 1) {
    counts.push(0L)
  }
  counts
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How long to wait before trying a request again.
///
/// The specification requires an exponential backoff with jitter so that a fleet
/// of exporters does not return to a recovering collector in step. The numbers are
/// the ones the reference implementations settled on: five seconds at first,
/// growing by half each time, never more than thirty, and a fifth of the wait
/// spread either way by the caller's own randomness.
#derive(Eq, Debug)
pub(all) struct Backoff {
  initial : Int64
  multiplier : Double
  maximum : Int64
  jitter : Double
}

///|
pub extend Backoff with Eq::{equal, not_equal}

///|
pub extend Backoff with Debug::{to_repr}

///|
/// The default: 5s, times 1.5, capped at 30s, with 20% jitter.
pub let otlp_backoff : Backoff = {
  initial: 5000L,
  multiplier: 1.5,
  maximum: 30000L,
  jitter: 0.2,
}

///|
/// A backoff with any of the four values changed.
pub fn Backoff::new(
  initial~ : Int64 = otlp_backoff.initial,
  multiplier~ : Double = otlp_backoff.multiplier,
  maximum~ : Int64 = otlp_backoff.maximum,
  jitter~ : Double = otlp_backoff.jitter,
) -> Backoff {
  { initial, multiplier, maximum, jitter, }
}

///|
/// The wait before attempt number `attempt`, counting the first retry as one.
///
/// `rand` is the caller's randomness: four octets are read for the jitter, and a
/// generator that returns anything else leaves the wait unjittered rather than
/// making the exporter fail. A delay is a scheduling decision, not a reason to
/// drop telemetry.
pub fn Backoff::delay(
  self : Backoff,
  attempt : Int32,
  rand : (Int32) -> Bytes,
) -> Int64 {
  let ceiling = self.maximum.to_double()
  let mut wait = self.initial.to_double()
  let mut step = 1
  while step < attempt && wait < ceiling {
    wait = wait * self.multiplier
    step = step + 1
  }
  if wait > ceiling {
    wait = ceiling
  }
  let spread = wait * self.jitter
  let bytes = rand(4)
  if bytes.length() != 4 {
    return wait.to_int64()
  }
  let mut bits : UInt64 = 0UL
  for byte in bytes {
    bits = (bits << 8) | byte.to_int().to_uint64()
  }
  // An interval of four octets over the whole of `UInt64`'s range, so the jitter
  // is uniform over `wait ± spread` rather than always late or always early.
  let fraction = bits.to_double() / 4294967296.0
  let low = wait - spread
  let high = wait + spread
  let jittered = (low + (high - low) * fraction).to_int64()
  // The maximum is a bound, not a starting point: a jittered wait that would
  // overrun it is the bound.
  if jittered > self.maximum {
    self.maximum
  } else {
    jittered
  }
}

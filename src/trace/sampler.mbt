// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a sampler is told about the span it is deciding on.
///
/// The four things a sampler may look at are all known before the span exists:
/// the parent, the trace id the span will carry, its name and its kind. Later
/// changes — a better name, an attribute discovered mid-request — cannot move the
/// decision, which is why the decision is made here and not on the finished span.
pub(all) struct SampleRequest {
  parent : TraceContext?
  trace_id : Bytes
  name : String
  kind : SpanKind
}

///|
/// Whether a span is wanted, and how much of it.
///
/// A caller can plug in its own: the four here are the ones the specification
/// names, and anything with a decision — a rate limit read from configuration, a
/// list of paths that must never be dropped — is another implementation of this.
pub(open) trait Sampler {
  /// Decide whether the span is wanted, and how much of it to record.
  fn should_sample(Self, SampleRequest) -> Decision
  /// A short name for logs and debug pages, e.g. `TraceIdRatioBased{0.25}`.
  fn description(Self) -> String
}

///|
/// The three answers a sampler can give.
#derive(Eq, Debug)
pub(all) enum Decision {
  /// Not recorded at all: the tracer hands back a span that forgets everything,
  /// so instrumented code needs no branch of its own.
  Drop
  /// Recorded but not sent on: the span keeps its attributes and reaches the
  /// sink, and the `sampled` bit stays clear so its children are dropped too.
  RecordOnly
  /// Recorded and sent on.
  RecordAndSample
}

///|
pub extend Decision with Eq::{equal, not_equal}

///|
pub extend Decision with Debug::{to_repr}

///|
/// Whether the span reaches the sink with data in it.
pub fn Decision::recording(self : Decision) -> Bool {
  self != Drop
}

///|
/// Whether the `sampled` bit is set and the trace continues.
pub fn Decision::sampled(self : Decision) -> Bool {
  self == RecordAndSample
}

///|
/// Samples everything, whatever the parent said. The starting point for a
/// service whose traffic is small enough to keep whole.
pub(all) struct Always {}

///|
pub let always : Always = Always::{ }

///|
pub impl Sampler for Always with fn should_sample(_, _) {
  RecordAndSample
}

///|
pub impl Sampler for Always with fn description(_) {
  "AlwaysOnSampler"
}

///|
pub extend Always with Sampler::{should_sample, description}

///|
/// Samples nothing. Useful behind `parent_based`, where it is the answer for a
/// parent that was not sampled.
pub(all) struct Never {}

///|
pub let never : Never = Never::{ }

///|
pub impl Sampler for Never with fn should_sample(_, _) {
  Drop
}

///|
pub impl Sampler for Never with fn description(_) {
  "AlwaysOffSampler"
}

///|
pub extend Never with Sampler::{should_sample, description}

///|
/// Samples a fixed fraction of traces, decided by the trace id rather than by a
/// coin: the same id gets the same answer on every hop, in every process, and
/// from every service, so a trace that one service keeps is not dropped by the
/// next.
///
/// The fraction is read off the low 64 bits of the trace id, which the
/// specification asks for so that two rates nest: raising the rate keeps every
/// trace the lower rate kept.
#derive(Debug)
pub(all) struct Ratio {
  ratio : Double
}

///|
pub extend Ratio with Debug::{to_repr}

///|
/// A ratio sampler. A `ratio` outside 0 to 1 is clamped, so configuration read
/// from a file cannot produce a sampler that samples more than everything or less
/// than nothing.
pub fn ratio(ratio~ : Double) -> Ratio {
  { ratio: if ratio < 0.0 { 0.0 } else if ratio > 1.0 { 1.0 } else { ratio }, }
}

///|
pub impl Sampler for Ratio with fn should_sample(self, request) {
  // Both ends are answered without arithmetic: a bound of `2^63` does not fit the
  // signed integer the comparison runs in, and "everything" and "nothing" need no
  // threshold anyway.
  if self.ratio >= 1.0 {
    return RecordAndSample
  }
  if self.ratio <= 0.0 {
    return Drop
  }
  // The threshold is `ratio * 2^63`, in the halved space the id is compared in:
  // shifting the id right by one leaves 63 bits, which an `Int64` holds as a
  // positive number, so both sides of the comparison live in the same scale.
  let bound : Int64 = (self.ratio * 9223372036854775808.0).to_int64()
  if sample_point(request.trace_id) < bound {
    RecordAndSample
  } else {
    Drop
  }
}

///|
pub impl Sampler for Ratio with fn description(self) {
  "TraceIdRatioBased{\{self.ratio}}"
}

///|
pub extend Ratio with Sampler::{should_sample, description}

///|
/// Follows the parent's decision and asks `root` only when there is no parent.
///
/// This is the sampler to give a service, because it is what keeps a distributed
/// trace whole: the hop that made the decision decided for the whole trace, and
/// every later hop obeys it instead of rolling its own dice.
///
/// The specification's five rows are the five fields: `root` without a parent,
/// then a parent from another process or this one, sampled or not. The default
/// for a sampled parent is `always` and for an unsampled one `never`, so a program
/// that names only `root` follows the parent.
pub(all) struct ParentBased {
  root : &Sampler
  remote_sampled : &Sampler
  remote_unsampled : &Sampler
  local_sampled : &Sampler
  local_unsampled : &Sampler
}

///|
/// Parent-based sampling over `root`, which decides for the first span of a
/// trace.
pub fn parent_based(
  root~ : &Sampler,
  remote_sampled~ : &Sampler = always,
  remote_unsampled~ : &Sampler = never,
  local_sampled~ : &Sampler = always,
  local_unsampled~ : &Sampler = never,
) -> ParentBased {
  { root, remote_sampled, remote_unsampled, local_sampled, local_unsampled, }
}

///|
pub impl Sampler for ParentBased with fn should_sample(self, request) {
  match request.parent {
    Some(parent) => {
      let delegate = match (parent.remote, parent.sampled()) {
        (true, true) => self.remote_sampled
        (true, false) => self.remote_unsampled
        (false, true) => self.local_sampled
        (false, false) => self.local_unsampled
      }
      delegate.should_sample(request)
    }
    None => self.root.should_sample(request)
  }
}

///|
pub impl Sampler for ParentBased with fn description(self) {
  "ParentBased{root=\{self.root.description()}}"
}

///|
pub extend ParentBased with Sampler::{should_sample, description}

///|
/// The low 64 bits of the trace id, halved. W3C Trace Context puts the trace id
/// in the first field of `traceparent`, and the ratio decision reads its tail so
/// that a 128-bit id and the 64-bit ids older systems have agree on the answer.
fn sample_point(trace_id : Bytes) -> Int64 {
  let mut v : UInt64 = 0UL
  for i in 8..<16 {
    if i < trace_id.length() {
      v = (v << 8) | trace_id[i].to_int().to_uint64()
    }
  }
  (v >> 1).reinterpret_as_int64()
}

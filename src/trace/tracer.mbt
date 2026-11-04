// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Makes spans, and the one place ids and the sampling decision are settled.
///
/// A tracer holds three things it cannot invent for itself: where randomness comes
/// from, where finished spans go, and who decides whether a trace is wanted. The
/// clock is the fourth, and it does not even reach the tracer — every call that
/// needs a time is handed one.
pub struct Tracer {
  rand : (Int32) -> Bytes
  sink : &Sink
  sampler : &Sampler
  limits : Limits
}

///|
/// A tracer drawing ids from `rand`, handing finished spans to `sink`, and asking
/// `sampler` about every span it starts.
///
/// `rand(n)` must return exactly `n` octets and must not return all zeros: eight
/// octets of zeros is not a valid span id, and a generator that produces one is
/// broken rather than unlucky. A call that breaks either rule makes `start`
/// refuse; see `Refused::Ids` and `Refused::Zero`.
pub fn Tracer::new(
  rand~ : (Int32) -> Bytes,
  sink~ : &Sink,
  sampler~ : &Sampler,
  limits~ : Limits = trace_limits,
) -> Tracer {
  { rand, sink, sampler, limits, }
}

///|
/// Start a span.
///
/// With a `parent` whose context is valid, the new span joins that trace: it takes
/// the parent's trace id and trace state, and `parent_based` sampling follows the
/// parent's decision. Without one it starts a trace of its own, with a fresh trace
/// id and no vendor state.
///
/// `at` is the start of the operation in nanoseconds. `attributes` and `links` are
/// set before the span is handed back; a sampler sees them, which is why they are
/// parameters here rather than calls on the span afterwards.
pub fn Tracer::start(
  self : Tracer,
  name : String,
  parent? : TraceContext,
  kind~ : SpanKind = Internal,
  at~ : Int64,
  attributes~ : Array[(String, Value)] = [],
  links~ : Array[Link] = [],
) -> Span raise Refused {
  let parent = match parent {
    Some(p) if p.is_valid() => Some(p)
    _ => None
  }
  // A trace id is needed before the sampler is asked, because the sampler's
  // answer for a ratio sampler is a function of it.
  let trace_id = match parent {
    Some(p) => p.trace_id
    None => self.mint(16)
  }
  let decision = self.sampler.should_sample({ parent, trace_id, name, kind, })
  // Minted whatever the decision: a dropped span still has an identity, so
  // logs and events recorded elsewhere can name it.
  let span_id = self.mint(8)
  let flags = match parent {
    Some(p) => p.with_sampled(sampled=decision.sampled()).flags
    None => if decision.sampled() { sampled_flag } else { b'\x00' }
  }
  let state = match parent {
    Some(p) => p.state
    None => empty_trace_state
  }
  let span = Span::new(
    { trace_id, span_id, flags, state, remote: false, },
    match parent {
      Some(p) => Some(p.span_id)
      None => None
    },
    kind,
    at,
    name,
    decision.recording(),
    self.sink,
    self.limits,
  )
  span.set_attributes(attributes)
  for link in links {
    span.add_link(link)
  }
  span
}

///|
/// `width` octets from the caller's generator, refused unless the shape is one an
/// id can take.
fn Tracer::mint(self : Tracer, width : Int32) -> Bytes raise Refused {
  let bytes = (self.rand)(width)
  if bytes.length() != width {
    raise Refused::Ids(want=width, got=bytes.length())
  }
  let mut non_zero = false
  for i in 0..<width {
    if bytes[i] != b'\x00' {
      non_zero = true
      break
    }
  }
  if !non_zero {
    raise Refused::Zero(at=0)
  }
  bytes
}

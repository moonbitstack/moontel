// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A sixteen-octet trace id from its hexadecimal spelling.
fn hex_id(hex : String) -> Bytes raise {
  @base16.decode(hex)
}

///|
/// A request for `trace_id`, as a sampler is handed one.
fn request(trace_id : Bytes) -> @trace.SampleRequest {
  { parent: None, trace_id, name: "op", kind: @trace.Internal, }
}

///|
test "the two fixed samplers answer the same way every time" {
  assert_eq(
    @trace.always.should_sample(
      request(hex_id("00000000000000000000000000000001")),
    ),
    @trace.RecordAndSample,
  )
  assert_eq(
    @trace.never.should_sample(
      request(hex_id("00000000000000000000000000000001")),
    ),
    @trace.Drop,
  )
  assert_eq(@trace.always.description(), "AlwaysOnSampler")
  assert_eq(@trace.never.description(), "AlwaysOffSampler")
}

///|
test "a ratio of one samples and a ratio of zero does not" {
  assert_eq(
    @trace.ratio(ratio=1.0).should_sample(
      request(hex_id("ffffffffffffffffffffffffffffffff")),
    ),
    @trace.RecordAndSample,
  )
  assert_eq(
    @trace.ratio(ratio=0.0).should_sample(
      request(hex_id("00000000000000000000000000000001")),
    ),
    @trace.Drop,
  )
}

///|
test "a ratio outside zero to one is clamped" {
  // Configuration read from a file is not to be trusted with the range.
  assert_eq(@trace.ratio(ratio=7.0).ratio, 1.0)
  assert_eq(@trace.ratio(ratio=-0.5).ratio, 0.0)
  assert_eq(@trace.ratio(ratio=0.25).description(), "TraceIdRatioBased{0.25}")
}

///|
test "a ratio reads the low 64 bits of the trace id and nothing else" {
  // The threshold is the low 64 bits halved against `ratio * 2^63`, so an id whose
  // tail is zero is always sampled and one whose tail is all ones never is, at any
  // ratio strictly between zero and one.
  let zero_tail = hex_id("0123456789abcdef0000000000000000")
  let full_tail = hex_id("0123456789abcdefffffffffffffffff")
  for p in [0.001, 0.25, 0.5, 0.999] {
    let sampler = @trace.ratio(ratio=p)
    assert_eq(sampler.should_sample(request(zero_tail)), @trace.RecordAndSample)
    assert_eq(sampler.should_sample(request(full_tail)), @trace.Drop)
  }
}

///|
test "a ratio compares the halved id against the threshold, not against half of it" {
  // At a half, the threshold is 2^62, so an id whose low 64 bits are 2^63 lands
  // exactly on it and is not sampled: the comparison is `<`, which is what keeps
  // two implementations that wrote the same id in different words agreeing about
  // the decision.
  let at_bound = hex_id("0123456789abcdef8000000000000000")
  let just_below = hex_id("0123456789abcdef7fffffffffffffff")
  let half = @trace.ratio(ratio=0.5)
  assert_eq(half.should_sample(request(at_bound)), @trace.Drop)
  assert_eq(half.should_sample(request(just_below)), @trace.RecordAndSample)
  // A quarter moves the threshold to 2^61 and takes the same two ids with it.
  let quarter = @trace.ratio(ratio=0.25)
  assert_eq(quarter.should_sample(request(at_bound)), @trace.Drop)
  assert_eq(quarter.should_sample(request(just_below)), @trace.Drop)
  let quarter_below = hex_id("0123456789abcdef4000000000000000")
  let quarter_at = hex_id("0123456789abcdef3fffffffffffffff")
  assert_eq(quarter.should_sample(request(quarter_below)), @trace.Drop)
  assert_eq(quarter.should_sample(request(quarter_at)), @trace.RecordAndSample)
}

///|
test "raising a ratio keeps every trace the lower one kept" {
  // W3C and OpenTelemetry both ask for this: a backend running at a higher rate
  // must see a superset of what the edge saw, or a trace is half collected.
  let lower = @trace.ratio(ratio=0.25)
  let higher = @trace.ratio(ratio=0.5)
  let mut sampled_any = false
  for i in 0..<256 {
    let id = hex_id("0123456789abcdef0000000000000000")
    let bytes : Array[Byte] = []
    for j in 0..<16 {
      bytes.push(id[j])
    }
    // Walk the tail so the ids differ in the bits the decision reads.
    bytes[8] = (i >> 8).to_byte()
    bytes[15] = i.to_byte()
    let candidate = Bytes::from_array(bytes)
    if lower.should_sample(request(candidate)) == @trace.RecordAndSample {
      sampled_any = true
      assert_eq(
        higher.should_sample(request(candidate)),
        @trace.RecordAndSample,
      )
    }
  }
  assert_true(sampled_any)
}

///|
test "a ratio ignores the parent's sampled flag" {
  // OpenTelemetry's TraceIdRatioBased is defined for the root of a trace; a hop
  // that honoured the parent here would make it a parent-based sampler by accident.
  let parent = @trace.TraceContext::new(
    trace_id=hex_id("0123456789abcdef0000000000000000"),
    span_id=hex_id("0123456789abcdef"),
    flags=b'\x00',
  )
  let trace_id = hex_id("0123456789abcdef0000000000000000")
  let from_parent = @trace.ratio(ratio=0.5).should_sample({
    parent: Some(parent),
    trace_id,
    name: "op",
    kind: @trace.Server,
  })
  assert_eq(from_parent, @trace.RecordAndSample)
}

///|
test "parent-based sampling follows the parent and asks the root only without one" {
  let root = @trace.ratio(ratio=0.0)
  let sampler = @trace.parent_based(root~)
  let trace_id = hex_id("0123456789abcdef0000000000000001")
  let sampled_parent = @trace.TraceContext::new(
    trace_id~,
    span_id=hex_id("0123456789abcdef"),
    flags=@trace.sampled_flag,
  )
  let unsampled_parent = sampled_parent.with_sampled(sampled=false)
  assert_eq(
    sampler.should_sample({
      parent: Some(sampled_parent),
      trace_id,
      name: "op",
      kind: @trace.Server,
    }),
    @trace.RecordAndSample,
  )
  // The parent decided the whole trace; the root sampler, which would drop, is not
  // consulted.
  assert_eq(
    sampler.should_sample({
      parent: Some(unsampled_parent),
      trace_id,
      name: "op",
      kind: @trace.Server,
    }),
    @trace.Drop,
  )
  assert_eq(
    sampler.should_sample({
      parent: None,
      trace_id,
      name: "op",
      kind: @trace.Server,
    }),
    @trace.Drop,
  )
}

///|
test "a sampler's description names its parameter" {
  let description = @trace.parent_based(root=@trace.ratio(ratio=0.5)).description()
  assert_eq(description, "ParentBased{root=TraceIdRatioBased{0.5}}")
  assert_eq(
    @trace.parent_based(root=@trace.always).description(),
    "ParentBased{root=AlwaysOnSampler}",
  )
}

///|
test "a decision knows how much of the span survives" {
  assert_false(@trace.Drop.recording())
  assert_false(@trace.Drop.sampled())
  assert_true(@trace.RecordOnly.recording())
  assert_false(@trace.RecordOnly.sampled())
  assert_true(@trace.RecordAndSample.recording())
  assert_true(@trace.RecordAndSample.sampled())
}

///|
test "a sampler of the caller's own is one trait implementation away" {
  let refusing : &@trace.Sampler = @trace.Never::{ }
  assert_eq(
    refusing.should_sample(request(hex_id("00000000000000000000000000000001"))),
    @trace.Drop,
  )
}

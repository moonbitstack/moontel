// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A sampler that remembers what it was asked and answers `RecordOnly`.
struct RecordingSampler {
  seen : Ref[Array[@trace.SampleRequest]]
  decision : @trace.Decision
}

///|
impl @trace.Sampler for RecordingSampler with fn should_sample(self, request) {
  self.seen.val.push(request)
  self.decision
}

///|
impl @trace.Sampler for RecordingSampler with fn description(_) {
  "RecordingSampler"
}

///|
fn recording_sampler(decision~ : @trace.Decision) -> RecordingSampler {
  { seen: Ref([]), decision, }
}

///|
test "a root span gets a fresh trace and a fresh span id" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.always,
  )
  let span = tracer.start("GET /orders", at=100L)
  let context = span.context()
  assert_eq(context.trace_id.length(), 16)
  assert_eq(context.span_id.length(), 8)
  assert_true(context.sampled())
  assert_true(context.state.is_empty())
  span.finish(at=200L)
  let data = recorder.spans()[0]
  assert_eq(data.parent, None)
  assert_eq(data.kind, @trace.Internal)
  assert_eq(data.start, 100L)
  assert_eq(data.end, 200L)
  assert_true(data.sampled())
}

///|
test "two spans never share an id" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.always,
  )
  let first = tracer.start("a", at=1L)
  let second = tracer.start("b", at=2L)
  assert_eq(first.context().trace_id == second.context().trace_id, false)
  assert_eq(first.context().span_id == second.context().span_id, false)
}

///|
test "a child joins its parent's trace under a new span id" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.always,
  )
  let parent = tracer.start("parent", at=10L)
  let child = tracer.start(
    "child",
    parent=parent.context(),
    kind=@trace.Server,
    at=11L,
  )
  assert_eq(child.context().trace_id, parent.context().trace_id)
  assert_eq(child.context().span_id == parent.context().span_id, false)
  assert_eq(child.context().state, parent.context().state)
  child.finish(at=12L)
  let data = recorder.spans()[0]
  assert_eq(data.parent, Some(parent.context().span_id))
  assert_eq(data.kind, @trace.Server)
}

///|
test "a parent context that is not a trace starts a new one" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.always,
  )
  let short = @trace.TraceContext::new(
    trace_id=Bytes::make(15, b'\x01'),
    span_id=Bytes::make(8, b'\x02'),
  )
  let span = tracer.start("op", parent=short, at=1L)
  assert_eq(span.context().trace_id == short.trace_id, false)
}

///|
test "a parent's flags travel to the child, sampled bit included" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.parent_based(root=@trace.always),
  )
  let parent = @trace.TraceContext::new(
    trace_id=Bytes::make(16, b'\x05'),
    span_id=Bytes::make(8, b'\x06'),
    flags=@trace.sampled_flag | @trace.random_flag,
  )
  let child = tracer.start("op", parent~, at=1L)
  assert_eq(child.context().flags, @trace.sampled_flag | @trace.random_flag)
}

///|
test "a parent that was not sampled leaves the child out of the trace" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.parent_based(root=@trace.always),
  )
  let parent = @trace.TraceContext::new(
    trace_id=Bytes::make(16, b'\x05'),
    span_id=Bytes::make(8, b'\x06'),
  )
  let child = tracer.start("op", parent~, at=1L)
  assert_false(child.is_recording())
  assert_false(child.context().sampled())
  child.finish(at=2L)
  assert_eq(recorder.len(), 0)
}

///|
test "the sampler is asked with the trace id the span will carry" {
  let recorder = @trace.Recorder::new()
  let sampler = recording_sampler(decision=@trace.RecordAndSample)
  let tracer = @trace.Tracer::new(rand=counting_rand(), sink=recorder, sampler~)
  let span = tracer.start("GET /orders", kind=@trace.Client, at=1L)
  let request = sampler.seen.val[0]
  assert_eq(request.trace_id, span.context().trace_id)
  assert_eq(request.name, "GET /orders")
  assert_eq(request.kind, @trace.Client)
  assert_eq(request.parent, None)
}

///|
test "record only keeps the data and clears the sampled bit" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=recording_sampler(decision=@trace.RecordOnly),
  )
  let span = tracer.start("op", at=1L)
  assert_true(span.is_recording())
  span.set_attribute("kept", @trace.Bool(true))
  span.finish(at=2L)
  // The sink is the processor seam, so it sees the span; `sampled` is what an
  // exporter looks at before shipping it anywhere.
  assert_eq(recorder.len(), 1)
  assert_false(recorder.spans()[0].sampled())
  assert_eq(recorder.spans()[0].attributes, [("kept", @trace.Bool(true))])
}

///|
test "attributes and links given to start are on the span before it is handed back" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.always,
  )
  let other = @trace.TraceContext::new(
    trace_id=Bytes::make(16, b'\x0b'),
    span_id=Bytes::make(8, b'\x0c'),
  )
  let span = tracer.start("op", at=1L, attributes=[("a", @trace.Str("1"))], links=[
    { context: other, attributes: [], },
  ])
  assert_eq(span.attributes(), [("a", @trace.Str("1"))])
  assert_eq(span.links().length(), 1)
}

///|
test "a generator that returns the wrong width is refused" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=_ => Bytes::make(4, b'\x01'),
    sink=recorder,
    sampler=@trace.always,
  )
  let refused = try {
    tracer.start("op", at=1L) |> ignore
    false
  } catch {
    @trace.Refused::Ids(want~, got~) => want == 16 && got == 4
    _ => false
  }
  assert_true(refused)
}

///|
test "a generator that returns zero octets is refused" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=zero_rand(),
    sink=recorder,
    sampler=@trace.always,
  )
  let refused = try {
    tracer.start("op", at=1L) |> ignore
    false
  } catch {
    @trace.Refused::Zero(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "a span finished before it started keeps the times it was given" {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=counting_rand(),
    sink=recorder,
    sampler=@trace.always,
  )
  let span = tracer.start("op", at=500L)
  span.finish(at=400L)
  let data = recorder.spans()[0]
  assert_eq(data.start, 500L)
  assert_eq(data.end, 400L)
  assert_eq(data.duration(), -100L)
}

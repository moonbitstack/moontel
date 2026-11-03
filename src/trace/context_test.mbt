// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The context every test below parses back out of a header.
let sample_traceparent : String = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

///|
test "a context writes the traceparent W3C Trace Context defines" {
  let context = @trace.TraceContext::new(
    trace_id=@base16.decode("0af7651916cd43dd8448eb211c80319c"),
    span_id=@base16.decode("b7ad6b7169203331"),
    flags=@trace.sampled_flag,
  )
  assert_eq(context.to_traceparent(), sample_traceparent)
  assert_true(context.sampled())
  assert_true(context.is_valid())
  assert_eq(context.state, @trace.empty_trace_state)
}

///|
test "the flags are written as two lowercase hexadecimal digits" {
  let context = @trace.TraceContext::new(
    trace_id=@base16.decode("0af7651916cd43dd8448eb211c80319c"),
    span_id=@base16.decode("b7ad6b7169203331"),
    flags=b'\xa3',
  )
  assert_eq(
    context.to_traceparent(),
    "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-a3",
  )
}

///|
test "a context is valid only with the two id widths, neither all zero" {
  let trace_id = @base16.decode("0af7651916cd43dd8448eb211c80319c")
  let span_id = @base16.decode("b7ad6b7169203331")
  assert_true(@trace.TraceContext::new(trace_id~, span_id~).is_valid())
  assert_false(
    @trace.TraceContext::new(trace_id=Bytes::make(15, b'\x01'), span_id~).is_valid(),
  )
  assert_false(
    @trace.TraceContext::new(trace_id=Bytes::make(17, b'\x01'), span_id~).is_valid(),
  )
  assert_false(
    @trace.TraceContext::new(trace_id~, span_id=Bytes::make(7, b'\x01')).is_valid(),
  )
  assert_false(
    @trace.TraceContext::new(trace_id=Bytes::make(16, b'\x00'), span_id~).is_valid(),
  )
  assert_false(
    @trace.TraceContext::new(trace_id~, span_id=Bytes::make(8, b'\x00')).is_valid(),
  )
}

///|
test "clearing the sampled bit leaves the other flags alone" {
  let context = @trace.TraceContext::new(
    trace_id=@base16.decode("0af7651916cd43dd8448eb211c80319c"),
    span_id=@base16.decode("b7ad6b7169203331"),
    flags=@trace.sampled_flag | @trace.random_flag,
  )
  let cleared = context.with_sampled(sampled=false)
  assert_false(cleared.sampled())
  assert_eq(cleared.flags, @trace.random_flag)
  let set = cleared.with_sampled(sampled=true)
  assert_true(set.sampled())
  // Both bits are on the wire again, and the level-2 `random` bit never moved.
  assert_eq(
    set.to_traceparent(),
    "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-03",
  )
}

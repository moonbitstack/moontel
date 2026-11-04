// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "extract reads the three headers, whatever their case" {
  let extracted = @propagate.extract([
    ("TraceParent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
    ("TRACESTATE", "foo=1"),
    ("Baggage", "userId=alice"),
  ])
  match extracted.context {
    Some(context) => {
      assert_eq(
        @base16.encode(context.trace_id[:]),
        "4bf92f3577b34da6a3ce929d0e0e4736",
      )
      assert_eq(context.state.get("foo"), Some("1"))
    }
    None => fail("the context was not read")
  }
  assert_eq(extracted.baggage.get("userId"), Some("alice"))
}

///|
test "extract leaves an unreadable field empty and the rest of the request intact" {
  let extracted = @propagate.extract([
    ("traceparent", "00-00000000000000000000000000000000-00f067aa0ba902b7-01"),
    ("tracestate", "foo=1"),
    ("baggage", "userId=alice"),
  ])
  assert_eq(extracted.context, None)
  // The vendor state hangs off a trace that was refused, so it goes too; the bag
  // is independent of the trace and survives.
  assert_eq(extracted.baggage.get("userId"), Some("alice"))
}

///|
test "two traceparent headers refuse each other" {
  let extracted = @propagate.extract([
    ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
    ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4737-00f067aa0ba902b7-01"),
  ])
  assert_eq(extracted.context, None)
}

///|
test "several tracestate headers are one comma-joined list" {
  let extracted = @propagate.extract([
    ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
    ("tracestate", "foo=1"),
    ("tracestate", "bar=2"),
  ])
  match extracted.context {
    Some(context) => assert_eq(context.state.to_header(), "foo=1,bar=2")
    None => fail("the context was not read")
  }
}

///|
test "inject replaces the propagation headers and leaves the others alone" {
  let context = @propagate.parse_traceparent(
    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"[:],
  )
  let outgoing = @propagate.inject(
    [
      ("content-type", "application/json"),
      ("traceparent", "00-12345678901234567890123456789012-1234567890123456-01"),
      ("tracestate", "stale=1"),
      ("baggage", "stale=1"),
      ("x-request-id", "abc"),
    ],
    {
      context: Some(context),
      baggage: @propagate.Baggage::parse("userId=alice"[:]),
    },
  )
  assert_eq(outgoing, [
    ("content-type", "application/json"),
    ("x-request-id", "abc"),
    ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
    ("baggage", "userId=alice"),
  ])
}

///|
test "inject without a context removes a stale traceparent rather than keeping it" {
  let outgoing = @propagate.inject(
    [
      ("traceparent", "00-12345678901234567890123456789012-1234567890123456-01"),
      ("tracestate", "foo=1"),
      ("accept", "*/*"),
    ],
    { context: None, baggage: @propagate.empty_baggage, },
  )
  assert_eq(outgoing, [("accept", "*/*")])
}

///|
test "inject writes the vendor state only when there is some" {
  let plain = @trace.TraceContext::new(
    trace_id=hex("4bf92f3577b34da6a3ce929d0e0e4736"),
    span_id=hex("00f067aa0ba902b7"),
    flags=@trace.sampled_flag,
  )
  let with_state = @propagate.parse(
    plain.to_traceparent()[:],
    tracestate="foo=1"[:],
  )
  let bare = @propagate.inject([], {
    context: Some(plain),
    baggage: @propagate.empty_baggage,
  })
  assert_eq(bare.length(), 1)
  let stated = @propagate.inject([], {
    context: Some(with_state),
    baggage: @propagate.empty_baggage,
  })
  assert_eq(stated, [
    ("traceparent", plain.to_traceparent()),
    ("tracestate", "foo=1"),
  ])
}

///|
test "a context that is not a trace is not written at all" {
  let broken = @trace.TraceContext::new(
    trace_id=Bytes::make(15, b'\x01'),
    span_id=Bytes::make(8, b'\x02'),
  )
  let outgoing = @propagate.inject([], {
    context: Some(broken),
    baggage: @propagate.empty_baggage,
  })
  assert_eq(outgoing, [])
}

///|
test "what extract reads, inject writes back unchanged" {
  let inbound = [
    ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
    ("tracestate", "foo=1,bar=2"),
    ("baggage", "userId=alice,serverNode=DF%2028"),
  ]
  let extracted = @propagate.extract(inbound)
  let outgoing = @propagate.inject([], extracted)
  assert_eq(outgoing, inbound)
}

///|
test "a context read off the wire is remote, and one minted here is not" {
  let read = @propagate.parse_traceparent(
    "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
  )
  assert_true(read.remote)
  let made = @trace.TraceContext::new(
    trace_id=read.trace_id,
    span_id=read.span_id,
  )
  assert_false(made.remote)
}

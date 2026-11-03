// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A `traceparent` that parses, in the spelling W3C Trace Context uses in its
/// examples.
let valid_traceparent : String = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

///|
test "a traceparent round-trips through parse and back" {
  let context = @propagate.parse_traceparent(valid_traceparent[:])
  assert_eq(
    @base16.encode(context.trace_id[:]),
    "4bf92f3577b34da6a3ce929d0e0e4736",
  )
  assert_eq(@base16.encode(context.span_id[:]), "00f067aa0ba902b7")
  assert_true(context.sampled())
  assert_eq(context.to_traceparent(), valid_traceparent)
}

///|
test "all eight trace flag bits are carried" {
  for flags in ["00", "01", "02", "03", "7f", "a3", "ff"] {
    let text = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-" + flags
    let context = @propagate.parse_traceparent(text[:])
    assert_eq(context.to_traceparent(), text)
  }
}

///|
test "a version above zero may append fields after a dash" {
  let text = "cc-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra-fields"
  let context = @propagate.parse_traceparent(text[:])
  assert_eq(
    @base16.encode(context.trace_id[:]),
    "4bf92f3577b34da6a3ce929d0e0e4736",
  )
  // The hop writes version 00: a field it does not understand is not passed on,
  // and the specification expects a hop to write the version it speaks.
  assert_eq(context.to_traceparent(), valid_traceparent)
}

///|
test "a refused traceparent says where and what was expected" {
  let too_short = try {
    @propagate.parse_traceparent("00-1"[:]) |> ignore
    fail("a short header parsed")
  } catch {
    @trace.Refused::Field(want~, ..) => want
    _ => fail("wrong refusal")
  }
  assert_eq(too_short, "the 55 characters of a traceparent")

  // An uppercase digit is refused at the offset it sits at, because a lowercase
  // parser and an uppercase one would disagree about which trace a request is in.
  let uppercase = try {
    @propagate.parse_traceparent(
      "00-4BF92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"[:],
    )
    |> ignore
    fail("an uppercase id parsed")
  } catch {
    @trace.Refused::NotHex(at~) => at
    _ => fail("wrong refusal")
  }
  assert_eq(uppercase, 4)

  let zero = try {
    @propagate.parse_traceparent(
      "00-00000000000000000000000000000000-00f067aa0ba902b7-01"[:],
    )
    |> ignore
    fail("an all-zero trace id parsed")
  } catch {
    @trace.Refused::Zero(at~) => at
    _ => fail("wrong refusal")
  }
  assert_eq(zero, 3)
}

///|
test "the version field refuses ff" {
  let refused = try {
    @propagate.parse_traceparent(
      "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"[:],
    )
    |> ignore
    false
  } catch {
    @trace.Refused::Field(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "version 00 ends at fifty-five characters" {
  let refused = try {
    @propagate.parse_traceparent(
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01x"[:],
    )
    |> ignore
    false
  } catch {
    @trace.Refused::Field(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "whitespace around the value is dropped, whitespace inside is not" {
  let padded = " \t" + valid_traceparent + "\t "
  let context = @propagate.parse_traceparent(padded[:])
  assert_eq(context.to_traceparent(), valid_traceparent)
  let refused = try {
    @propagate.parse_traceparent(
      "00 -4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"[:],
    )
    |> ignore
    false
  } catch {
    @trace.Refused::NotHex(..) | @trace.Refused::Field(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "parse attaches the vendor state that came with the trace" {
  let context = @propagate.parse(
    valid_traceparent[:],
    tracestate="foo=1,bar=2"[:],
  )
  assert_eq(context.state.to_header(), "foo=1,bar=2")
  assert_eq(
    @propagate.parse_tracestate("foo=1,bar=2"[:]).to_header(),
    "foo=1,bar=2",
  )
  // Without a second argument there is no state to attach.
  assert_true(@propagate.parse(valid_traceparent[:]).state.is_empty())
}

///|
test "parse refuses a tracestate it cannot read" {
  // `parse` is the explicit call: a caller that asked for both fields is told that
  // one of them is unusable. `extract` takes the tolerant road instead.
  let refused = try {
    @propagate.parse(valid_traceparent[:], tracestate="FOO=1"[:]) |> ignore
    false
  } catch {
    @trace.Refused::Field(..) => true
    _ => false
  }
  assert_true(refused)
}

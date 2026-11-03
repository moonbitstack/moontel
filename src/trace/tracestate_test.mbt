// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Whether `text` parses as a `tracestate` value.
fn accepts_tracestate(text : String) -> Bool {
  try {
    @trace.TraceState::parse(text[:]) |> ignore
    true
  } catch {
    _ => false
  }
}

///|
test "a tracestate keeps its members in order" {
  let state = @trace.TraceState::parse("foo=1,bar=2,baz=3")
  assert_eq(state.len(), 3)
  assert_eq(state.to_header(), "foo=1,bar=2,baz=3")
  assert_eq(state.get("bar"), Some("2"))
  assert_eq(state.get("nope"), None)
  assert_false(state.is_empty())
}

///|
test "an empty tracestate is no tracestate" {
  assert_true(@trace.TraceState::parse("").is_empty())
  assert_eq(@trace.TraceState::parse("").to_header(), "")
  assert_true(@trace.empty_trace_state.is_empty())
  assert_eq(@trace.empty_trace_state.len(), 0)
}

///|
test "whitespace before a member and after a value is dropped" {
  let state = @trace.TraceState::parse(" foo=1 \t , \t bar=2, \t baz=3")
  assert_eq(state.len(), 3)
  assert_eq(state.get("foo"), Some("1"))
  assert_eq(state.get("bar"), Some("2"))
  assert_eq(state.get("baz"), Some("3"))
  assert_eq(state.to_header(), "foo=1,bar=2,baz=3")
}

///|
test "a member may not contain whitespace around its equals sign" {
  // W3C Trace Context §3.3.1 puts no OWS inside a list-member, and a hop that
  // trimmed it would accept a header no conforming sender writes.
  assert_false(accepts_tracestate("foo =1"))
  assert_false(accepts_tracestate("foo = 1"))
}

///|
test "keys follow the grammar, values follow theirs" {
  assert_true(accepts_tracestate("foo=1"))
  assert_true(accepts_tracestate("foo_bar-baz*qux/quux=1"))
  assert_true(accepts_tracestate("a1=1"))
  assert_true(accepts_tracestate("tenant@system=1"))
  assert_true(accepts_tracestate("1tenant@system=1"))
  // Uppercase is not in the key grammar, and neither is a dot.
  assert_false(accepts_tracestate("FOO=1"))
  assert_false(accepts_tracestate("foo.bar=1"))
  // A value may not carry the two characters that would end or split a member.
  assert_false(accepts_tracestate("foo=bar=baz"))
  assert_false(accepts_tracestate("foo=bar,baz"))
  // An empty value has no `nblk-chr` to end on.
  assert_false(accepts_tracestate("foo="))
  // A space may appear inside a value; one at the end of a member is the OWS
  // around that member, and the member is trimmed before it is checked.
  assert_true(accepts_tracestate("foo=bar baz"))
  assert_eq(@trace.TraceState::parse("foo=bar ").get("foo"), Some("bar"))
}

///|
test "a key follows the interoperability suite's reading, at signs included" {
  // `[0-9a-z][_0-9a-z-*/@]{0,255}`: the suite's own checker, which is wider than
  // W3C Trace Context §3.3.1's ABNF. The wider reading is deliberate — see the
  // note on `check_key` — and it is wider in exactly these three shapes.
  assert_true(accepts_tracestate("tenant@system=1"))
  assert_true(accepts_tracestate("1tenant@system=1"))
  assert_true(accepts_tracestate("foo@=1"))
  assert_true(accepts_tracestate("foo@@bar=1"))
  assert_true(accepts_tracestate("t@\{"v".repeat(15)}=1"))
  assert_true(accepts_tracestate("\{"t".repeat(242)}@v=1"))
  // A key still has to start with a lowercase letter or a digit, so a leading at
  // sign is out even under the wider reading.
  assert_false(accepts_tracestate("@foo=1"))
}

///|
test "a key is at most 256 characters long" {
  assert_true(accepts_tracestate("\{"z".repeat(256)}=1"))
  assert_false(accepts_tracestate("\{"z".repeat(257)}=1"))
}

///|
test "a value is at most 256 characters long" {
  assert_true(accepts_tracestate("foo=\{"v".repeat(256)}"))
  assert_false(accepts_tracestate("foo=\{"v".repeat(257)}"))
}

///|
test "a list of 32 members is accepted and 33 are refused" {
  let members : Array[String] = []
  for i in 0..<32 {
    members.push("k\{i}=\{i}")
  }
  let ok = @trace.TraceState::parse(members.join(","))
  assert_eq(ok.len(), 32)
  assert_eq(ok.to_header(), members.join(","))
  members.push("k32=32")
  assert_false(accepts_tracestate(members.join(",")))
}

///|
test "the first of two members with one key wins" {
  // W3C Trace Context level 2 allows either dropping the duplicate or passing the
  // list on as it came; keeping the first member is what the interoperability
  // suite's reference checker does, so a hop that sees the same list as another
  // hop agrees with it about the value.
  assert_eq(@trace.TraceState::parse("foo=1,foo=2").to_header(), "foo=1")
  assert_eq(
    @trace.TraceState::parse("foo=1,bar=2,foo=1").to_header(),
    "foo=1,bar=2",
  )
}

///|
test "a member with no equals sign is refused" {
  assert_false(accepts_tracestate("foo"))
  assert_false(accepts_tracestate("foo=1,bar"))
}

///|
test "inserting a member puts it closest to this hop" {
  let state = @trace.TraceState::parse("foo=1,bar=2")
  let updated = state.insert(key="baz", value="3")
  assert_eq(updated.to_header(), "baz=3,foo=1,bar=2")
  // Replacing a key keeps its value current without duplicating the member.
  let replaced = updated.insert(key="bar", value="9")
  assert_eq(replaced.to_header(), "bar=9,baz=3,foo=1")
  assert_eq(replaced.len(), 3)
}

///|
test "inserting past 32 members drops the rightmost" {
  let members : Array[String] = []
  for i in 0..<32 {
    members.push("k\{i}=\{i}")
  }
  let state = @trace.TraceState::parse(members.join(","))
  let updated = state.insert(key="new", value="1")
  assert_eq(updated.len(), 32)
  assert_eq(updated.get("new"), Some("1"))
  assert_eq(updated.get("k31"), None)
  assert_eq(updated.get("k30"), Some("30"))
}

///|
test "inserting a key or value outside the grammar is refused" {
  let state = @trace.empty_trace_state
  let upper = try {
    state.insert(key="FOO", value="1") |> ignore
    false
  } catch {
    @trace.Refused::Field(..) => true
    _ => false
  }
  assert_true(upper)
  let empty = try {
    state.insert(key="foo", value="") |> ignore
    false
  } catch {
    @trace.Refused::Field(..) => true
    _ => false
  }
  assert_true(empty)
}

///|
test "deleting a member leaves the rest in order" {
  let state = @trace.TraceState::parse("foo=1,bar=2,baz=3")
  assert_eq(state.delete("bar").to_header(), "foo=1,baz=3")
  assert_eq(state.delete("nope").to_header(), "foo=1,bar=2,baz=3")
}

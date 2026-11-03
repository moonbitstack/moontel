// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Whether `text` parses as a `baggage` value.
fn accepts_baggage(text : String) -> Bool {
  try {
    @propagate.Baggage::parse(text[:]) |> ignore
    true
  } catch {
    _ => false
  }
}

///|
test "a bag keeps its members in order and reads them back" {
  let bag = @propagate.Baggage::parse("userId=alice,serverNode=DF%2028"[:])
  assert_eq(bag.len(), 2)
  assert_eq(bag.get("userId"), Some("alice"))
  assert_eq(bag.get("serverNode"), Some("DF 28"))
  assert_eq(bag.to_header(), "userId=alice,serverNode=DF%2028")
  assert_true(@propagate.Baggage::parse(""[:]).is_empty())
  assert_false(bag.is_empty())
}

///|
test "whitespace around members and around the equals sign is dropped" {
  let bag = @propagate.Baggage::parse("  userId = alice ,  serverNode=DF28 "[:])
  assert_eq(bag.get("userId"), Some("alice"))
  assert_eq(bag.to_header(), "userId=alice,serverNode=DF28")
}

///|
test "a value may be empty and may carry equals signs" {
  let bag = @propagate.Baggage::parse("empty=,base64=aGk="[:])
  assert_eq(bag.get("empty"), Some(""))
  // W3C Baggage §3.2.2.2 warns parsers not to assume `=` only separates key from
  // value; everything after the first one is part of the value.
  assert_eq(bag.get("base64"), Some("aGk="))
  // `=` is a `baggage-octet`, so it travels unescaped and the next hop splits at
  // the first one just as this one did.
  assert_eq(bag.to_header(), "empty=,base64=aGk=")
}

///|
test "properties ride along without being understood" {
  let bag = @propagate.Baggage::parse("k=v;one=1;two"[:])
  let entry = bag.members[0]
  assert_eq(entry.properties.length(), 2)
  assert_eq(entry.properties[0].key, "one")
  assert_eq(entry.properties[0].value, Some("1"))
  assert_eq(entry.properties[1].key, "two")
  assert_eq(entry.properties[1].value, None)
  assert_eq(bag.to_header(), "k=v;one=1;two")
}

///|
test "percent escapes are decoded to text and re-encoded on the way out" {
  let bag = @propagate.Baggage::parse("k=caf%C3%A9%20au%20lait"[:])
  assert_eq(bag.get("k"), Some("café au lait"))
  assert_eq(bag.to_header(), "k=caf%C3%A9%20au%20lait")
  // The percent sign itself has to be escaped, or the next hop would read a
  // sequence the sender never wrote.
  let with_percent = @propagate.Baggage::new(members=[
    { key: "k", value: "100%", properties: [], },
  ])
  assert_eq(with_percent.to_header(), "k=100%25")
  assert_eq(
    @propagate.Baggage::parse(with_percent.to_header()[:]).get("k"),
    Some("100%"),
  )
}

///|
test "a sequence that is not UTF-8 becomes the replacement character" {
  // W3C Baggage §3.2.2.2 asks for U+FFFD rather than a refused header: the value is
  // opaque to this hop, and dropping the bag over one bad octet loses the good ones.
  let bag = @propagate.Baggage::parse("k=a%FFb"[:])
  assert_eq(bag.get("k"), Some("a\u{FFFD}b"))
}

///|
test "a member that does not match the grammar refuses the header" {
  assert_false(accepts_baggage("no-equals"))
  assert_false(accepts_baggage("k=v,no-equals"))
  // A key is an RFC 7230 token: no spaces, no colons, no quotes.
  assert_false(accepts_baggage("a b=v"))
  assert_false(accepts_baggage("k:=v"))
  assert_false(accepts_baggage("k=\"v\""))
}

///|
test "a bag of 64 members is accepted and 65 are refused" {
  let members : Array[String] = []
  for i in 0..<64 {
    members.push("k\{i}=v\{i}")
  }
  let at_limit = @propagate.Baggage::parse(members.join(",")[:])
  assert_eq(at_limit.len(), 64)
  members.push("k64=v64")
  assert_false(accepts_baggage(members.join(",")))
  assert_eq(@propagate.baggage_member_limit, 64)
  assert_eq(@propagate.baggage_byte_limit, 8192)
}

///|
test "a bag over 8192 octets is refused" {
  // The limit is on the whole header, not on one member: W3C Baggage §3.2.1.3
  // counts the combination.
  let value = "v".repeat(256)
  let members : Array[String] = []
  for i in 0..<20 {
    members.push("k\{i}=\{value}")
  }
  let under = members.join(",")
  assert_true(under.length() + 20 < 8192)
  assert_true(accepts_baggage(under))
  // One member of the same shape, long enough on its own, crosses the line.
  assert_false(accepts_baggage("k=" + "v".repeat(8192)))
  assert_true(accepts_baggage("k=" + "v".repeat(8188)))
}

///|
test "duplicate keys are kept in the order they arrived" {
  // W3C Baggage §3.2.1.1 allows a bag to carry one key twice and asks a hop to
  // preserve the order when it mutates the list, so `get` answers with the first.
  let bag = @propagate.Baggage::parse("k=1,k=2"[:])
  assert_eq(bag.len(), 2)
  assert_eq(bag.get("k"), Some("1"))
  assert_eq(bag.to_header(), "k=1,k=2")
}

///|
test "adding a member past the limit leaves the bag as it was" {
  let members : Array[@propagate.Member] = []
  for i in 0..<64 {
    members.push({ key: "k\{i}", value: "v", properties: [], })
  }
  let full = @propagate.Baggage::new(members~)
  let unchanged = full.add({ key: "extra", value: "v", properties: [], })
  assert_eq(unchanged.len(), 64)
  assert_eq(unchanged.get("extra"), None)
}

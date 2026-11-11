// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "an attribute set is the same set whatever order its entries arrive in" {
  let first = Attributes::new(entries=[
    ("b", @trace.Str("2")),
    ("a.b", @trace.Int(1L)),
  ])
  let second = Attributes::new(entries=[
    ("a.b", @trace.Int(1L)),
    ("b", @trace.Str("2")),
  ])
  assert_eq(first, second)
  assert_eq(first.identity(), second.identity())
  assert_eq(first.to_array()[0].0, "a.b")
  assert_eq(first.len(), 2)
}

///|
test "a dotted key is carried unchanged and the last value of a key wins" {
  let attributes = Attributes::new(entries=[
    ("gen_ai.request.model", @trace.Str("first")),
    ("gen_ai.request.model", @trace.Str("second")),
  ])
  assert_eq(attributes.len(), 1)
  assert_eq(attributes.get("gen_ai.request.model"), Some(@trace.Str("second")))
  assert_true(attributes.identity().contains("gen_ai.request.model"))
}

///|
test "a string and an integer of the same text are two different dimensions" {
  let text = Attributes::new(entries=[("k", @trace.Str("12"))])
  let number = Attributes::new(entries=[("k", @trace.Int(12L))])
  assert_true(text.identity() != number.identity())
  let empty = empty_attributes
  assert_eq(empty.len(), 0)
  assert_true(empty.identity() != text.identity())
}

///|
test "with_attribute returns a new set and leaves the old one alone" {
  let original = Attributes::new(entries=[("k", @trace.Str("old"))])
  let changed = original.with_attribute("k", @trace.Str("new"))
  assert_eq(original.get("k"), Some(@trace.Str("old")))
  assert_eq(changed.get("k"), Some(@trace.Str("new")))
  let grown = changed.with_attribute("a", @trace.Bool(true))
  assert_eq(grown.len(), 2)
  assert_eq(grown.to_array()[0].0, "a")
  assert_eq(grown.get("missing"), None)
}

///|
test "the GenAI group spells every key from the semantic conventions" {
  let attributes = gen_ai_client_attributes(
    provider="acme",
    operation="chat",
    request_model="model-a",
    response_model="model-a-v2",
    agent_name="support",
    conversation_id="thread-1",
  )
  assert_eq(attributes.len(), 6)
  for key in gen_ai_metric_keys {
    assert_true(key.contains("."))
    assert_true(attributes.get(key) is Some(_))
  }
  assert_eq(
    attributes.get(@semconv.gen_ai_provider_name),
    Some(@trace.Str("acme")),
  )
  assert_eq(
    attributes.get(@semconv.gen_ai_operation_name),
    Some(@trace.Str("chat")),
  )
  assert_true(attributes.identity().contains(@semconv.gen_ai_request_model))
}

///|
test "only the three required GenAI keys are set when the rest are unknown" {
  let attributes = gen_ai_client_attributes(
    provider="acme",
    operation="chat",
    request_model="model-a",
  )
  assert_eq(attributes.len(), 3)
  assert_eq(attributes.get(@semconv.gen_ai_response_model), None)
}

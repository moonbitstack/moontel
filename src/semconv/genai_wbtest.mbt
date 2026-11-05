// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "an attribute key is the name the registry gives it" {
  assert_eq(gen_ai_operation_name, "gen_ai.operation.name")
  assert_eq(gen_ai_request_model, "gen_ai.request.model")
  assert_eq(gen_ai_response_model, "gen_ai.response.model")
  assert_eq(gen_ai_usage_input_tokens, "gen_ai.usage.input_tokens")
  assert_eq(gen_ai_provider_name, "gen_ai.provider.name")
  assert_eq(gen_ai_agent_id, "gen_ai.agent.id")
}

///|
test "a metric name is the name the registry gives it" {
  assert_eq(
    gen_ai_client_operation_duration, "gen_ai.client.operation.duration",
  )
  assert_eq(
    gen_ai_client_inference_duration, "gen_ai.client.inference.duration",
  )
  assert_eq(
    gen_ai_client_inference_usage_input_tokens, "gen_ai.client.inference.usage.input_tokens",
  )
}

///|
test "a span type and an event name are the names the registry gives them" {
  assert_eq(gen_ai_client_inference, "gen_ai.client.inference")
  assert_eq(gen_ai_client_embeddings, "gen_ai.client.embeddings")
  assert_eq(
    gen_ai_client_inference_operation_details, "gen_ai.client.inference.operation.details",
  )
}

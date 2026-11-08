// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "a path becomes the method of the service that serves it" {
  assert_eq(
    service_path("http://localhost:4318/v1/traces"),
    "/opentelemetry.proto.collector.trace.v1.TraceService/Export",
  )
  assert_eq(
    service_path("http://localhost:4318/v1/metrics"),
    "/opentelemetry.proto.collector.metrics.v1.MetricsService/Export",
  )
  assert_eq(
    service_path("http://localhost:4318/v1/logs"),
    "/opentelemetry.proto.collector.logs.v1.LogsService/Export",
  )
}

///|
test "a path that names no signal is refused rather than guessed at" {
  let refused = try {
    ignore(service_path("http://localhost:4318/healthz"))
    None
  } catch {
    error => Some(error)
  }
  assert_true(refused is Some(_))
}

///|
test "a gRPC status becomes the status the retry rules know" {
  // OK is an acceptance; the three the specification calls retryable are the ones
  // the HTTP rules already retry; everything else is final.
  assert_eq(status_of(0), 200)
  assert_eq(status_of(8), 429)
  assert_eq(status_of(14), 503)
  assert_eq(status_of(4), 504)
  assert_eq(status_of(3), 400)
  assert_eq(status_of(13), 400)
}

///|
test "a request that is not protobuf is refused before it is sent" {
  let json = try {
    require_protobuf([("Content-Type", "application/json")])
    None
  } catch {
    error => Some(error)
  }
  assert_true(json is Some(_))
  // No content type at all is just as unreadable to the other side.
  let missing = try {
    require_protobuf([])
    None
  } catch {
    error => Some(error)
  }
  assert_true(missing is Some(_))
  // The header is matched without regard to case, like every header.
  require_protobuf([("content-type", "Application/X-Protobuf")])
}

///|
test "headers become metadata, except the content type gRPC decides for itself" {
  let metadata = metadata_of([
    ("Content-Type", "application/x-protobuf"),
    ("x-api-key", "secret"),
    ("Authorization", "Bearer token"),
  ])
  assert_eq(metadata.length(), 2)
  // The order of the caller's headers is kept, and the one header the protocol owns
  // is not among them.
  assert_eq(metadata[0].ascii(), ("x-api-key", "secret"))
  assert_eq(metadata[1].ascii(), ("Authorization", "Bearer token"))
}

///|
/// A hosted backend puts the OTLP endpoints under a prefix of its own, and only the
/// last segment decides which signal this is: the method is what the service serves,
/// not what the base URL happens to look like.
test "a base path in front of the signal does not change the method" {
  assert_eq(
    service_path("https://api.smith.langchain.com/otel/v1/traces"),
    "/opentelemetry.proto.collector.trace.v1.TraceService/Export",
  )
  assert_eq(
    service_path("https://api.smith.langchain.com/otel/v1/logs"),
    "/opentelemetry.proto.collector.logs.v1.LogsService/Export",
  )
  assert_eq(
    service_path("https://collector.example/otlp/v1/metrics"),
    "/opentelemetry.proto.collector.metrics.v1.MetricsService/Export",
  )
}

///|
/// The translation exists for the retry rules, so what has to hold is the verdict
/// rather than the number: the three situations the protocol calls retryable are
/// retried, and every other status ends the attempts instead of repeating them.
test "a gRPC status keeps the verdict the HTTP statuses already have" {
  assert_eq(@otlp.verdict(status_of(0)), @otlp.Accepted)
  assert_eq(@otlp.verdict(status_of(8)), @otlp.Retry)
  assert_eq(@otlp.verdict(status_of(14)), @otlp.Retry)
  assert_eq(@otlp.verdict(status_of(4)), @otlp.Retry)
  // The codes the protocol does not name: a retry would repeat the same answer.
  for code in [1, 2, 3, 5, 6, 7, 9, 10, 11, 12, 13, 15, 16] {
    assert_eq(@otlp.verdict(status_of(code)), @otlp.Rejected)
  }
}

///|
/// A call with no headers at all is still a call. The content type is the one
/// header the transport never passes on, whatever case it arrives in, because gRPC
/// announces its own.
test "no headers is no metadata" {
  assert_eq(metadata_of([]).length(), 0)
  assert_eq(
    metadata_of([("CONTENT-TYPE", "application/x-protobuf")]).length(),
    0,
  )
}

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

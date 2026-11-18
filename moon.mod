name = "moonbitstack/moontel"

version = "0.2.3"

readme = "README.md"

repository = "https://github.com/moonbitstack/moontel"

license = "Apache-2.0"

keywords = [
  "opentelemetry",
  "otel",
  "otlp",
  "otlp-json",
  "otlp-http",
  "otlp-protobuf",
  "otlp-grpc",
  "protobuf",
  "grpc",
  "tracing",
  "distributed-tracing",
  "trace-context",
  "w3c-trace-context",
  "traceparent",
  "tracestate",
  "baggage",
  "span",
  "sampler",
  "propagation",
  "metrics",
  "meter",
  "counter",
  "updowncounter",
  "gauge",
  "histogram",
  "summary",
  "metric-sdk",
  "cardinality",
  "exemplar",
  "logs",
  "logging",
  "log-record",
  "semconv",
  "semantic-conventions",
  "genai",
  "exporter",
  "batching",
  "retry",
  "backoff",
  "prometheus",
  "observability",
  "telemetry",
  "instrumentation",
  "asgi",
  "moonbit",
]

description = "OpenTelemetry for MoonBit."

source = "src"

import {
  "moonbitstack/moonast@0.3.2",
  "moonbitlang/parser@0.4.9",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonasgi@0.11.3",
  "moonbitstack/moonbase@0.5.1",
  "moonbitstack/moonseed@0.2.1",
  "moonbitstack/moonfetch@0.2.1",
  "moonbitstack/moonlog@0.2.1",
  "moonbitstack/moonzip@0.4.1",
  "moonbitstack/moonp8s@0.2.1",
  "moonbitstack/moonjson@0.5.1",
  "moonbitstack/moonrpc@0.22.3",
  "moonbitstack/moonhttp@0.16.1",
  "moonbitstack/moonproto@0.2.1",
}

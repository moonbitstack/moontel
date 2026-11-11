// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The span model, the tracer, the samplers and the sink seam.
pub using @trace {
  type Always,
  type Decision,
  type Discard,
  type Dropped,
  type Event,
  type Limits,
  type Link,
  type Never,
  type ParentBased,
  type Ratio,
  type Recorder,
  type Refused,
  type SampleRequest,
  trait Sampler,
  trait Sink,
  type Span,
  type SpanData,
  type SpanKind,
  type Status,
  type TraceContext,
  type TraceState,
  type Value,
  always,
  discard,
  dropped_nothing,
  empty_trace_state,
  never,
  parent_based,
  random_flag,
  ratio,
  sampled_flag,
  trace_limits,
  tracestate_limit,
}

///|
/// W3C Trace Context and W3C Baggage on the wire.
pub using @propagate {
  type Baggage,
  type Extracted,
  type Member,
  type Property,
  baggage_byte_limit,
  baggage_header,
  baggage_member_limit,
  empty_baggage,
  extract,
  inject,
  parse,
  parse_traceparent,
  parse_tracestate,
  traceparent_header,
  tracestate_header,
}

///|
/// The ASGI middleware that opens a server span per request.
pub using @asgi {type Tracing, method_and_path}

///|
/// Log records and the logger that writes them.
///
/// A program that wants a log sink under this name imports `moontel/log` and writes
/// `@log.Recorder`, because this facade already has a `Recorder` and a `Sink`: the
/// trace package's. Two seams with one name, kept apart by the package that owns
/// them.
pub using @log {
  type Fanout,
  type LogRecord,
  type Logger,
  type Severity,
  type SpanEvents,
}

///|
/// The OTel-style meter and its four instruments. `@meter.Refused` is not
/// re-exported: the facade already carries the trace package's `Refused`, and a
/// name that raises is read through the package that owns it.
pub using @meter {
  type Attributes,
  type Counter,
  type Gauge,
  type Histogram,
  type InstrumentKind,
  type Meter,
  type MeterLimits,
  type MeterProvider,
  type UpDownCounter,
  default_buckets,
  empty_attributes,
  gen_ai_client_attributes,
  gen_ai_metric_keys,
  instrument_name_limit,
  is_valid_name,
  meter_limits,
}

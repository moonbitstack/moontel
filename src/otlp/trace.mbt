// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Encode finished spans as an OTLP/JSON `ExportTraceServiceRequest`.
///
/// The body is what `POST /v1/traces` takes: one resource, one scope, and the
/// spans. Field names are the lowerCamelCase of the protobuf schema, ids are
/// hexadecimal and timestamps are decimal strings, which is the mapping the OTLP
/// specification fixes for JSON.
pub fn encode_traces(
  spans : Array[@trace.SpanData],
  resource~ : Resource = unknown_service,
  scope~ : Scope = moonbit_scope,
) -> String {
  let w = JsonWriter::new()
  w.open_object()
  w.name("resourceSpans")
  w.open_array()
  w.open_object()
  w.name("resource")
  write_resource(w, resource)
  w.name("scopeSpans")
  w.open_array()
  w.open_object()
  w.name("scope")
  write_scope(w, scope)
  w.name("spans")
  w.open_array()
  for span in spans {
    write_span(w, span)
  }
  w.close_array()
  w.close_object()
  w.close_array()
  w.close_object()
  w.close_array()
  w.close_object()
  w.text()
}

///|
fn write_span(w : JsonWriter, span : @trace.SpanData) -> Unit {
  w.open_object()
  w.name("traceId")
  w.string(@base16.encode(span.context.trace_id[:]))
  w.name("spanId")
  w.string(@base16.encode(span.context.span_id[:]))
  match span.parent {
    Some(parent) => {
      w.name("parentSpanId")
      w.string(@base16.encode(parent[:]))
    }
    None => ()
  }
  w.name("name")
  w.string(span.name)
  w.name("kind")
  w.raw(kind_code(span.kind).to_string())
  w.name("startTimeUnixNano")
  w.int64(span.start)
  w.name("endTimeUnixNano")
  w.int64(span.end)
  if !span.attributes.is_empty() {
    w.name("attributes")
    write_attributes(w, span.attributes)
  }
  if !span.events.is_empty() {
    w.name("events")
    w.open_array()
    for event in span.events {
      w.open_object()
      w.name("timeUnixNano")
      w.int64(event.at)
      w.name("name")
      w.string(event.name)
      if !event.attributes.is_empty() {
        w.name("attributes")
        write_attributes(w, event.attributes)
      }
      w.close_object()
    }
    w.close_array()
  }
  if !span.links.is_empty() {
    w.name("links")
    w.open_array()
    for link in span.links {
      w.open_object()
      w.name("traceId")
      w.string(@base16.encode(link.context.trace_id[:]))
      w.name("spanId")
      w.string(@base16.encode(link.context.span_id[:]))
      if !link.attributes.is_empty() {
        w.name("attributes")
        write_attributes(w, link.attributes)
      }
      w.close_object()
    }
    w.close_array()
  }
  match span.status {
    @trace.Unset => ()
    @trace.Ok => {
      w.name("status")
      w.open_object()
      w.name("code")
      w.raw("1")
      w.close_object()
    }
    @trace.Error(message) => {
      w.name("status")
      w.open_object()
      w.name("code")
      w.raw("2")
      if message != "" {
        w.name("message")
        w.string(message)
      }
      w.close_object()
    }
  }
  let dropped = span.dropped
  if dropped.attributes > 0 {
    w.name("droppedAttributesCount")
    w.raw(dropped.attributes.to_string())
  }
  if dropped.events > 0 {
    w.name("droppedEventsCount")
    w.raw(dropped.events.to_string())
  }
  if dropped.links > 0 {
    w.name("droppedLinksCount")
    w.raw(dropped.links.to_string())
  }
  if span.context.flags != b'\x00' {
    w.name("flags")
    w.raw(span.context.flags.to_int().to_string())
  }
  w.close_object()
}

///|
/// The number OTLP gives a span kind: `SPAN_KIND_INTERNAL` is 1, and the four kinds
/// that describe a position in a distributed call follow it.
fn kind_code(kind : @trace.SpanKind) -> Int32 {
  match kind {
    @trace.Internal => 1
    @trace.Server => 2
    @trace.Client => 3
    @trace.Producer => 4
    @trace.Consumer => 5
  }
}

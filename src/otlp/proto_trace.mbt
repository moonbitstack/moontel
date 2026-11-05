// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Encode finished spans as an OTLP `ExportTraceServiceRequest` in the binary
/// protobuf encoding.
///
/// The same request the JSON encoder produces, in the encoding the protocol treats
/// as the default: `/v1/traces` with `Content-Type: application/x-protobuf`. Field
/// numbers are the ones in `opentelemetry-proto`'s `trace/v1/trace.proto`, which do
/// not change; an id is the sixteen or eight bytes it is, not the hex of it.
pub fn encode_traces_protobuf(
  spans : Array[@trace.SpanData],
  resource~ : Resource = unknown_service,
  scope~ : Scope = moonbit_scope,
) -> Bytes {
  let request = ProtoWriter::new()
  let resource_spans = ProtoWriter::new()
  resource_spans.message(1, resource_message(resource))
  let scope_spans = ProtoWriter::new()
  scope_spans.message(1, scope_message(scope))
  for span in spans {
    scope_spans.message(2, span_message(span))
  }
  resource_spans.message(2, scope_spans)
  request.message(1, resource_spans)
  request.finish()
}

///|
fn span_message(span : @trace.SpanData) -> ProtoWriter {
  let w = ProtoWriter::new()
  w.bytes(1, span.context.trace_id[:])
  w.bytes(2, span.context.span_id[:])
  match span.parent {
    Some(parent) => w.bytes(4, parent[:])
    None => ()
  }
  w.string(5, span.name)
  w.enum_code(6, kind_code(span.kind))
  w.fixed64(7, span.start.reinterpret_as_uint64())
  w.fixed64(8, span.end.reinterpret_as_uint64())
  write_key_values(w, 9, span.attributes)
  if span.dropped.attributes > 0 {
    w.uint32(10, span.dropped.attributes)
  }
  for event in span.events {
    w.message(11, event_message(event))
  }
  if span.dropped.events > 0 {
    w.uint32(12, span.dropped.events)
  }
  for link in span.links {
    w.message(13, link_message(link))
  }
  if span.dropped.links > 0 {
    w.uint32(14, span.dropped.links)
  }
  match span.status {
    @trace.Unset => ()
    @trace.Ok => {
      let status = ProtoWriter::new()
      status.enum_code(3, 1)
      w.message(15, status)
    }
    @trace.Error(message) => {
      let status = ProtoWriter::new()
      status.enum_code(3, 2)
      if message != "" {
        status.string(2, message)
      }
      w.message(15, status)
    }
  }
  if span.context.flags != b'\x00' {
    w.fixed32(16, span.context.flags.to_int().reinterpret_as_uint())
  }
  w
}

///|
fn event_message(event : @trace.Event) -> ProtoWriter {
  let w = ProtoWriter::new()
  w.fixed64(1, event.at.reinterpret_as_uint64())
  w.string(2, event.name)
  write_key_values(w, 3, event.attributes)
  w
}

///|
fn link_message(link : @trace.Link) -> ProtoWriter {
  let w = ProtoWriter::new()
  w.bytes(1, link.context.trace_id[:])
  w.bytes(2, link.context.span_id[:])
  write_key_values(w, 4, link.attributes)
  w
}

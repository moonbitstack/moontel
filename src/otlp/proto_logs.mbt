// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Encode log records as an OTLP `ExportLogsServiceRequest` in the binary protobuf
/// encoding: the same request as the JSON encoder, for
/// `/v1/logs` with `Content-Type: application/x-protobuf`.
///
/// Records are grouped by the scope they were written under, which is what the
/// message nests on; the order of first appearance is kept, so a reader of the
/// payload sees the scopes in the order the program used them.
pub fn encode_logs_protobuf(
  records : Array[@log.LogRecord],
  resource~ : Resource = unknown_service,
  scope~ : Scope = moonbit_scope,
) -> Bytes {
  let request = ProtoWriter::new()
  let resource_logs = ProtoWriter::new()
  resource_logs.message(1, resource_message(resource))
  let names : Array[String] = []
  for record in records {
    if !names.contains(record.scope) {
      names.push(record.scope)
    }
  }
  for name in names {
    let scope_logs = ProtoWriter::new()
    // A record written without a scope of its own belongs to the exporter's, the
    // same way the JSON encoder decides it.
    scope_logs.message(
      1,
      scope_message({
        ..scope,
        name: if name == "" {
          scope.name
        } else {
          name
        },
      }),
    )
    for record in records {
      if record.scope == name {
        scope_logs.message(2, log_record_message(record))
      }
    }
    resource_logs.message(2, scope_logs)
  }
  request.message(1, resource_logs)
  request.finish()
}

///|
fn log_record_message(record : @log.LogRecord) -> ProtoWriter {
  let w = ProtoWriter::new()
  match record.time {
    Some(time) => w.fixed64(1, time.reinterpret_as_uint64())
    None => ()
  }
  w.enum_code(2, record.severity.number())
  w.string(3, record.severity_text())
  w.message(5, any_value(record.body))
  write_key_values(w, 6, record.attributes)
  if record.dropped > 0 {
    w.uint32(7, record.dropped)
  }
  match record.context() {
    Some(context) => {
      w.bytes(9, context.trace_id[:])
      w.bytes(10, context.span_id[:])
      if context.flags != b'\x00' {
        w.fixed32(8, context.flags.to_int().reinterpret_as_uint())
      }
    }
    None => ()
  }
  w.fixed64(11, record.observed.reinterpret_as_uint64())
  match record.event_name {
    Some(name) => if name != "" { w.string(12, name) }
    None => ()
  }
  w
}

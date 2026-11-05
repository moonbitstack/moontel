// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Encode log records as an OTLP/JSON `ExportLogsServiceRequest`, the body
/// `POST /v1/logs` takes.
///
/// Records are grouped by the scope that wrote them, because a scope belongs to
/// the request rather than to a record: one exporter can carry the lines of
/// several loggers and the backend still sees which one wrote what.
pub fn encode_logs(
  records : Array[@log.LogRecord],
  resource~ : Resource = unknown_service,
  scope~ : Scope = moonbit_scope,
) -> String {
  let names : Array[String] = []
  for record in records {
    if !names.contains(record.scope) {
      names.push(record.scope)
    }
  }
  let w = JsonWriter::new()
  w.open_object()
  w.name("resourceLogs")
  w.open_array()
  w.open_object()
  w.name("resource")
  write_resource(w, resource)
  w.name("scopeLogs")
  w.open_array()
  for name in names {
    w.open_object()
    w.name("scope")
    // A record written without a scope of its own belongs to the exporter's: a
    // scope is what a backend groups by, and an empty name groups nothing.
    write_scope(w, {
      ..scope,
      name: if name == "" {
        scope.name
      } else {
        name
      },
    })
    w.name("logRecords")
    w.open_array()
    for record in records {
      if record.scope == name {
        write_log_record(w, record)
      }
    }
    w.close_array()
    w.close_object()
  }
  w.close_array()
  w.close_object()
  w.close_array()
  w.close_object()
  w.text()
}

///|
fn write_log_record(w : JsonWriter, record : @log.LogRecord) -> Unit {
  w.open_object()
  match record.time {
    Some(time) => {
      w.name("timeUnixNano")
      w.int64(time)
    }
    None => ()
  }
  w.name("observedTimeUnixNano")
  w.int64(record.observed)
  w.name("severityNumber")
  w.raw(record.severity.number().to_string())
  w.name("severityText")
  w.string(record.severity_text())
  w.name("body")
  write_any_value(w, record.body)
  if !record.attributes.is_empty() {
    w.name("attributes")
    write_attributes(w, record.attributes)
  }
  match record.context() {
    Some(context) => {
      w.name("traceId")
      w.string(@base16.encode(context.trace_id[:]))
      w.name("spanId")
      w.string(@base16.encode(context.span_id[:]))
      if context.flags != b'\x00' {
        w.name("flags")
        w.raw(context.flags.to_int().to_string())
      }
    }
    None => ()
  }
  match record.event_name {
    Some(name) =>
      if name != "" {
        w.name("eventName")
        w.string(name)
      }
    None => ()
  }
  if record.dropped > 0 {
    w.name("droppedAttributesCount")
    w.raw(record.dropped.to_string())
  }
  w.close_object()
}

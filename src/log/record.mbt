// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One log record, as OpenTelemetry's data model defines it: when it happened,
/// what it says, how urgent it is, the trace it belongs to, and the attributes it
/// carries.
///
/// It is a value. A sink may keep it, queue it, copy it or throw it away, and a
/// logger that has handed one over never sees it again.
///
/// `time` is `None` when the caller has no event time of its own — a record read
/// out of another logging library may know only when it was collected. The
/// observed time is always present, because a record that cannot say when it was
/// seen cannot be ordered at all.
#derive(Eq, Debug)
pub(all) struct LogRecord {
  time : Int64?
  observed : Int64
  severity : Severity
  /// The severity as the producer spelled it. `None` means the short name of
  /// `severity`, which is what most producers mean.
  severity_text : String?
  body : @trace.Value
  attributes : Array[(String, @trace.Value)]
  /// The trace this record was written inside, when it was written inside one.
  /// Both ids are present or neither is: a span id without its trace names
  /// nothing.
  trace_id : Bytes?
  span_id : Bytes?
  flags : Byte
  /// The name of the event this record describes, for a record that is also an
  /// event. Only a record with a name can become a span event.
  event_name : String?
  /// The instrumentation scope: which logger in the program wrote this.
  scope : String
  dropped : Int32
}

///|
pub extend LogRecord with Eq::{equal, not_equal}

///|
pub extend LogRecord with Debug::{to_repr}

///|
/// A record at `at`, observed at the same moment unless the caller says otherwise.
pub fn LogRecord::new(
  severity~ : Severity,
  body~ : @trace.Value,
  at~ : Int64,
  observed? : Int64,
  scope~ : String = "",
) -> LogRecord {
  {
    time: Some(at),
    observed: observed.unwrap_or(at),
    severity,
    severity_text: None,
    body,
    attributes: [],
    trace_id: None,
    span_id: None,
    flags: b'\x00',
    event_name: None,
    scope,
    dropped: 0,
  }
}

///|
/// The same record with one attribute added, replacing a value under the same key.
pub fn LogRecord::with_attribute(
  self : LogRecord,
  key : String,
  value : @trace.Value,
) -> LogRecord {
  let attributes : Array[(String, @trace.Value)] = []
  let mut replaced = false
  for attribute in self.attributes {
    if attribute.0 == key {
      attributes.push((key, value))
      replaced = true
    } else {
      attributes.push(attribute)
    }
  }
  if !replaced {
    attributes.push((key, value))
  }
  { ..self, attributes, }
}

///|
/// The same record carrying `context`'s trace and span ids and its flags. A record
/// written inside a span names that span, which is what lets a backend show the
/// log line beside the work it belongs to.
pub fn LogRecord::with_context(
  self : LogRecord,
  context : @trace.TraceContext,
) -> LogRecord {
  {
    ..self,
    trace_id: Some(context.trace_id),
    span_id: Some(context.span_id),
    flags: context.flags,
  }
}

///|
/// The same record with an event name, which is what makes it eligible to become a
/// span event.
pub fn LogRecord::with_event_name(
  self : LogRecord,
  event_name : String,
) -> LogRecord {
  { ..self, event_name: Some(event_name), }
}

///|
/// The same record timed at `at` instead of where it was.
pub fn LogRecord::with_time(self : LogRecord, at~ : Int64) -> LogRecord {
  { ..self, time: Some(at), }
}

///|
/// The severity as text: what the producer wrote, or the short name of the
/// severity when it wrote nothing.
pub fn LogRecord::severity_text(self : LogRecord) -> String {
  match self.severity_text {
    Some(text) => text
    None => self.severity.text()
  }
}

///|
/// When the record says it happened: its own time when it has one, and the moment
/// it was observed otherwise. This is the timestamp a backend orders on, so it is
/// never absent.
pub fn LogRecord::timestamp(self : LogRecord) -> Int64 {
  match self.time {
    Some(at) => at
    None => self.observed
  }
}

///|
/// The trace and span the record belongs to, or `None` when it names no trace or
/// names one that is not a trace: an id of the wrong width, or all zeros, is a
/// producer's mistake rather than a link.
pub fn LogRecord::context(self : LogRecord) -> @trace.TraceContext? {
  match (self.trace_id, self.span_id) {
    (Some(trace_id), Some(span_id)) => {
      let context = @trace.TraceContext::new(
        trace_id~,
        span_id~,
        flags=self.flags,
      )
      if context.is_valid() {
        Some(context)
      } else {
        None
      }
    }
    _ => None
  }
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Turns a named record into an event on the span it was written inside.
///
/// A log line that says "the payment was authorised" is also something that
/// happened during the request, and a trace reader wants it on the timeline rather
/// than in a separate list. Put this beside the exporter in a `Fanout` and the
/// record does both.
///
/// Only a record that names itself, names a valid trace and span, and names the
/// span this sink was built with becomes an event. The last condition is what keeps
/// a sink shared by a whole process from attaching one request's line to another
/// request's span.
pub struct SpanEvents {
  span : @trace.Span
}

///|
/// A sink that adds the records written inside `span` to `span` as events.
pub fn SpanEvents::new(span~ : @trace.Span) -> SpanEvents {
  { span, }
}

///|
pub impl Sink for SpanEvents with fn accept(self, record) {
  let event_name = match record.event_name {
    Some(name) => name
    None => return
  }
  if event_name == "" {
    return
  }
  let context = match record.context() {
    Some(context) => context
    None => return
  }
  if !self.span.is_recording() {
    return
  }
  let current = self.span.context()
  if context.trace_id != current.trace_id || context.span_id != current.span_id {
    return
  }
  self.span.add_event(
    event_name,
    attributes=record.attributes,
    at=record.timestamp(),
  )
}

///|
pub extend SpanEvents with Sink::{accept}

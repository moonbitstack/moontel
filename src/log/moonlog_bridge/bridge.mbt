// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Takes the records `moonlog` produces and writes them as telemetry.
///
/// A program already writes its lines through a structured logger; this is the sink
/// that puts those same lines on the trace they belong to, without the program
/// changing how it logs. The level, the message, the fields and the caller become a
/// record's severity, body, attributes and code location, and the span the sink was
/// built in becomes its trace and span ids.
///
/// What `moonlog` calls `spans` is the display path of the logger's own contexts,
/// not a trace id; the ids come from `current` instead, because only the caller
/// knows which span the work is happening in.
pub struct Bridge {
  sink : &@log.Sink
  now : () -> Int64
  current : @trace.TraceContext?
  scope : String
}

///|
/// A bridge writing to `sink`, timed by `now`.
///
/// `current` is the span the program is in, when it has one. A bridge without it
/// still writes every record: it just cannot say which trace the record belongs to,
/// which is the honest answer for a line written outside a request.
pub fn Bridge::new(
  sink~ : &@log.Sink,
  now~ : () -> Int64,
  current? : @trace.TraceContext,
  scope~ : String = "",
) -> Bridge {
  { sink, now, current, scope, }
}

///|
/// The same bridge writing inside `span`.
pub fn Bridge::inside(self : Bridge, span : @trace.Span) -> Bridge {
  { ..self, current: Some(span.context()), }
}

///|
/// The same bridge writing inside `context`.
pub fn Bridge::with_context(
  self : Bridge,
  context : @trace.TraceContext,
) -> Bridge {
  { ..self, current: Some(context), }
}

///|
/// Translate one `moonlog` entry.
///
/// The result is `Ok` once the record reached the sink: `moonlog`'s sink signature
/// reports a failure as text, and nothing here can fail in a way the logger could
/// act on — a record with no trace is still a record.
pub impl @moonlog.Sink for Bridge with fn write(self, entry) {
  let record = entry.record
  let at = if record.time != 0L { record.time } else { (self.now)() }
  let severity = @log.Severity::of_name(record.level.name()[:]).unwrap_or(
    @log.Info,
  )
  let mut out = @log.LogRecord::new(
    severity~,
    body=@trace.Str(record.msg),
    at~,
    observed=(self.now)(),
    scope=self.scope,
  )
  for field in record.fields {
    out = out.with_attribute(field.0, value_of(field.1))
  }
  out = with_caller(out, record.caller)
  match self.current {
    Some(context) => out = out.with_context(context)
    None => ()
  }
  self.sink.accept(out)
  Ok(())
}

///|
pub extend Bridge with @moonlog.Sink::{write}

///|
/// One field of the log line, as a telemetry attribute.
///
/// The four scalar shapes map to the four attribute types so a dashboard can sum a
/// number; a list, a map or an error keeps its text form instead of being flattened
/// into a type it is not.
fn value_of(value : @moonlog.Value) -> @trace.Value {
  match value {
    @moonlog.Null => @trace.Str("null")
    @moonlog.Bool(v) => @trace.Bool(v)
    @moonlog.Int(v) => @trace.Int(v)
    @moonlog.Float(v) => @trace.Double(v)
    @moonlog.Str(v) => @trace.Str(v)
    other => @trace.Str(other.encode())
  }
}

///|
/// Where the line was written, under the semantic conventions' `code` keys:
/// `code.filepath`, `code.function.name` and `code.lineno`.
fn with_caller(
  record : @log.LogRecord,
  caller : @moonlog.Caller,
) -> @log.LogRecord {
  let mut out = record
  match caller.file {
    Some(file) => out = out.with_attribute("code.filepath", @trace.Str(file))
    None => ()
  }
  match caller.func {
    Some(name) =>
      out = out.with_attribute("code.function.name", @trace.Str(name))
    None => ()
  }
  match caller.line {
    Some(line) =>
      out = out.with_attribute("code.lineno", @trace.Int(line.to_int64()))
    None => ()
  }
  out
}

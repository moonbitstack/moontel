// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Writes records to a sink, carrying the trace it was written inside.
///
/// A logger holds what every line from one part of a program shares: the scope it
/// names, the attributes it always carries, the severity below which nothing is
/// written, and the span the work is happening in. What changes per line is handed
/// to `log`.
///
/// It reads no clock of its own. `now` is the caller's, so a replay can write a
/// timeline it chose and a service can hand in whichever clock it already trusts.
pub struct Logger {
  sink : &Sink
  now : () -> Int64
  scope : String
  attributes : Array[(String, @trace.Value)]
  current : @trace.TraceContext?
  floor : Severity?
  trace_based : Bool
  limits : @trace.Limits
}

///|
/// A logger writing to `sink`, timed by `now`.
///
/// `floor` drops everything less urgent than it, `None` keeping every severity:
/// the default is to keep what the program writes and let the sink decide what to
/// do with it. `trace_based` drops records written inside a trace that was not
/// sampled, which is what keeps a sampled-down service from paying for log lines
/// about work no backend will ever see; records outside any trace are unaffected.
///
/// `limits` is the span limits type, and a logger reads two of its numbers:
/// `attributes` and `attribute_value_length`.
pub fn Logger::new(
  sink~ : &Sink,
  now~ : () -> Int64,
  scope~ : String = "",
  attributes~ : Array[(String, @trace.Value)] = [],
  floor? : Severity,
  trace_based~ : Bool = false,
  limits~ : @trace.Limits = @trace.trace_limits,
) -> Logger {
  { sink, now, scope, attributes, current: None, floor, trace_based, limits, }
}

///|
/// The same logger, naming `scope` instead. Nesting a scope is how a program says
/// "this line came from the payment part of the order service".
pub fn Logger::under(self : Logger, scope : String) -> Logger {
  { ..self, scope, }
}

///|
/// The same logger with one more attribute on every record it writes, replacing a
/// value under the same key.
pub fn Logger::with_attribute(
  self : Logger,
  key : String,
  value : @trace.Value,
) -> Logger {
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
/// The same logger writing inside `span`: every record it writes names that span's
/// trace and span ids.
pub fn Logger::inside(self : Logger, span : @trace.Span) -> Logger {
  { ..self, current: Some(span.context()), }
}

///|
/// The same logger writing inside `context`, which is what a caller that read a
/// `traceparent` off a request has rather than a span of its own.
pub fn Logger::with_context(
  self : Logger,
  context : @trace.TraceContext,
) -> Logger {
  { ..self, current: Some(context), }
}

///|
/// Whether a record of this severity would be written: false below the floor, and
/// false inside a trace that was not sampled when `trace_based` is on.
///
/// Instrumented code can ask before it builds an expensive body.
pub fn Logger::enabled(self : Logger, severity : Severity) -> Bool {
  match self.floor {
    Some(floor) => if !severity.at_least(floor) { return false }
    None => ()
  }
  if self.trace_based {
    match self.current {
      Some(context) => if !context.sampled() { return false }
      None => ()
    }
  }
  true
}

///|
/// The scope this logger names.
pub fn Logger::scope(self : Logger) -> String {
  self.scope
}

///|
/// Write one record.
///
/// `at` is when the event happened and `observed` is when the program noticed;
/// both default to the logger's clock. `error` adds the three exception attributes
/// — `exception.type`, `exception.message`, `exception.stacktrace` — and the
/// caller's own `attributes` win over them, as the specification asks: a producer
/// that knows better than the generic mapping keeps its value.
pub fn Logger::log(
  self : Logger,
  severity : Severity,
  body : @trace.Value,
  attributes~ : Array[(String, @trace.Value)] = [],
  at? : Int64,
  observed? : Int64,
  event_name? : String,
  error? : Error,
) -> Unit {
  guard self.enabled(severity) else { return }
  let at = at.unwrap_or((self.now)())
  let mut record = LogRecord::new(
    severity~,
    body~,
    at~,
    observed=observed.unwrap_or(at),
    scope=self.scope,
  )
  // The logger's own attributes first, then what the failure says, then the call's:
  // each knows more about the line than the one before it, so a key given twice
  // ends up with the value from the closest hand.
  let merged : Array[(String, @trace.Value)] = []
  for attribute in self.attributes {
    merged.push(attribute)
  }
  match error {
    Some(error) => merged.push(("exception.message", @trace.Str("\{error}")))
    None => ()
  }
  for attribute in attributes {
    let mut at = None
    for i, existing in merged {
      if existing.0 == attribute.0 {
        at = Some(i)
        break
      }
    }
    match at {
      Some(i) => merged[i] = attribute
      None => merged.push(attribute)
    }
  }
  let (kept, dropped) = bounded(merged, self.limits)
  record = { ..record, attributes: kept, dropped, }
  match self.current {
    Some(context) => record = record.with_context(context)
    None => ()
  }
  match event_name {
    Some(name) => record = record.with_event_name(name)
    None => ()
  }
  self.sink.accept(record)
}

///|
/// Write a record whose body is plain text.
pub fn Logger::write(
  self : Logger,
  severity : Severity,
  message : String,
  attributes~ : Array[(String, @trace.Value)] = [],
  at? : Int64,
  observed? : Int64,
  event_name? : String,
  error? : Error,
) -> Unit {
  self.log(
    severity,
    @trace.Str(message),
    attributes~,
    at?,
    observed?,
    event_name?,
    error?,
  )
}

///|
/// Write a `TRACE` record.
pub fn Logger::trace(
  self : Logger,
  message : String,
  attributes~ : Array[(String, @trace.Value)] = [],
  at? : Int64,
) -> Unit {
  self.write(Trace, message, attributes~, at?)
}

///|
/// Write a `DEBUG` record.
pub fn Logger::debug(
  self : Logger,
  message : String,
  attributes~ : Array[(String, @trace.Value)] = [],
  at? : Int64,
) -> Unit {
  self.write(Debug, message, attributes~, at?)
}

///|
/// Write an `INFO` record.
pub fn Logger::info(
  self : Logger,
  message : String,
  attributes~ : Array[(String, @trace.Value)] = [],
  at? : Int64,
) -> Unit {
  self.write(Info, message, attributes~, at?)
}

///|
/// Write a `WARN` record.
pub fn Logger::warn(
  self : Logger,
  message : String,
  attributes~ : Array[(String, @trace.Value)] = [],
  at? : Int64,
) -> Unit {
  self.write(Warn, message, attributes~, at?)
}

///|
/// Write an `ERROR` record.
pub fn Logger::error(
  self : Logger,
  message : String,
  attributes~ : Array[(String, @trace.Value)] = [],
  at? : Int64,
  error? : Error,
) -> Unit {
  self.write(Error, message, attributes~, at?, error?)
}

///|
/// Write a `FATAL` record.
pub fn Logger::fatal(
  self : Logger,
  message : String,
  attributes~ : Array[(String, @trace.Value)] = [],
  at? : Int64,
) -> Unit {
  self.write(Fatal, message, attributes~, at?)
}

// ------------------------------------------------------------------ internals

///|
/// The attributes a record may keep, and how many were refused.
///
/// The limit is per record and counts attributes, not bytes, exactly as the
/// specification's attribute limits do. A producer that loops over user data must
/// not be able to make one record unbounded.
fn bounded(
  attributes : Array[(String, @trace.Value)],
  limits : @trace.Limits,
) -> (Array[(String, @trace.Value)], Int32) {
  let kept : Array[(String, @trace.Value)] = []
  let mut dropped = 0
  for attribute in attributes {
    if kept.length() >= limits.attributes {
      dropped = dropped + 1
    } else {
      kept.push(
        (attribute.0, truncate(attribute.1, limits.attribute_value_length)),
      )
    }
  }
  (kept, dropped)
}

///|
/// A string attribute longer than the limit is cut to it, counting each character
/// as one, as OpenTelemetry's attribute limits ask. Every other type passes
/// through.
fn truncate(value : @trace.Value, limit : Int32?) -> @trace.Value {
  match (value, limit) {
    (@trace.Str(s), Some(n)) if s.length() > n =>
      @trace.Str(s.exact_view(start=0, end=n).to_owned())
    (@trace.Strs(xs), Some(n)) =>
      @trace.Strs(
        xs.map(s => {
          if s.length() > n {
            s.exact_view(start=0, end=n).to_owned()
          } else {
            s
          }
        }),
      )
    _ => value
  }
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a span is about, from the point of view of the process that made it.
/// The kind is part of the sampling input and of what a backend draws, so it is
/// settled when the span starts.
pub(all) enum SpanKind {
  Internal
  Server
  Client
  Producer
  Consumer
} derive(Eq, Debug)

///|
pub extend SpanKind with Eq::{equal, not_equal}

///|
pub extend SpanKind with Debug::{to_repr}

///|
/// How the operation ended, as the caller judges it.
///
/// The three values form a total order, `Ok` above `Error` above `Unset`, and a
/// status is judged against that order rather than by "last write wins": `Ok` is
/// final, `Error` may replace another `Error` because the message may improve, and
/// `Unset` is what a span already has.
///
/// `Unset` means "the caller has no opinion", which is not a failure: an
/// instrumentation library leaves it alone unless the semantic conventions say
/// otherwise.
pub(all) enum Status {
  Unset
  Ok
  Error(String)
} derive(Eq, Debug)

///|
pub extend Status with Eq::{equal, not_equal}

///|
pub extend Status with Debug::{to_repr}

///|
/// The status as text, with the description beside the code that carries it.
pub impl Show for Status with fn output(self, logger) {
  match self {
    Unset => logger.write_string("Unset")
    Ok => logger.write_string("Ok")
    Error(message) => {
      logger.write_string("Error(")
      logger.write_string(message)
      logger.write_char(')')
    }
  }
}

///|
pub extend Status with Show::{to_string, output}

///|
/// One attribute value.
///
/// The arrays are separate variants rather than one array of `Value` because
/// OpenTelemetry requires an array attribute to be homogeneous, and because that is
/// what an exporter has to write: a mixed array has no single type tag.
pub(all) enum Value {
  Bool(Bool)
  /// A signed 64-bit integer. Nanosecond timestamps and byte counts both fit; a
  /// `Double` would lose the low digits of a nanosecond clock.
  Int(Int64)
  Double(Double)
  Str(String)
  Bools(Array[Bool])
  Ints(Array[Int64])
  Doubles(Array[Double])
  Strs(Array[String])
} derive(Eq, Debug)

///|
pub extend Value with Eq::{equal, not_equal}

///|
pub extend Value with Debug::{to_repr}

///|
/// The value as text, for a log line or a debug page: strings quoted so that an
/// empty one is visible, arrays bracketed and comma-separated.
pub impl Show for Value with fn output(self, logger) {
  match self {
    Bool(value) => logger.write_string(value.to_string())
    Int(value) => logger.write_string(value.to_string())
    Double(value) => logger.write_string(value.to_string())
    Str(value) => {
      logger.write_char('"')
      logger.write_string(value)
      logger.write_char('"')
    }
    Bools(values) =>
      logger.write_string(text_of(values.map(v => v.to_string())))
    Ints(values) => logger.write_string(text_of(values.map(v => v.to_string())))
    Doubles(values) =>
      logger.write_string(text_of(values.map(v => v.to_string())))
    Strs(values) =>
      logger.write_string(text_of(values.map(v => "\"" + v + "\"")))
  }
}

///|
pub extend Value with Show::{to_string, output}

///|
fn text_of(items : Array[String]) -> String {
  "[" + items.join(", ") + "]"
}

///|
/// Something that happened during a span: a name, when it happened, and what it
/// carried. Events keep the order they were added in, which for timestamps handed
/// in by the caller is not necessarily the order of those timestamps.
pub(all) struct Event {
  name : String
  at : Int64
  attributes : Array[(String, Value)]
} derive(Eq, Debug)

///|
pub extend Event with Eq::{equal, not_equal}

///|
pub extend Event with Debug::{to_repr}

///|
/// A causal relationship to another span that is not this one's parent — a batch
/// item, a message consumed later, a fan-in. The linked context travels with the
/// link so a reader can join the two traces.
pub(all) struct Link {
  context : TraceContext
  attributes : Array[(String, Value)]
} derive(Eq, Debug)

///|
pub extend Link with Eq::{equal, not_equal}

///|
pub extend Link with Debug::{to_repr}

///|
/// How much a span gave up at its limits. OpenTelemetry asks for the counts rather
/// than for the dropped values, so a reader can tell "this span had no attributes"
/// from "this span had three hundred and we kept 128".
pub(all) struct Dropped {
  attributes : Int32
  events : Int32
  links : Int32
} derive(Eq, Debug)

///|
pub extend Dropped with Eq::{equal, not_equal}

///|
pub extend Dropped with Debug::{to_repr}

///|
/// Nothing dropped, the value a span starts with.
pub let dropped_nothing : Dropped = { attributes: 0, events: 0, links: 0, }

///|
/// A finished span, as a `Sink` receives it.
///
/// It is a value, not a handle: everything in it is settled, and a sink may keep
/// it, queue it or throw it away. Nothing here is normalised — a span may begin and
/// end at the same nanosecond, and an event may carry a time outside the span.
pub(all) struct SpanData {
  context : TraceContext
  /// The parent's span id, or `None` for the first span of a trace. The parent's
  /// own context is deliberately not carried: a child needs the id to say where it
  /// hangs, and nothing else about the parent.
  parent : Bytes?
  name : String
  kind : SpanKind
  start : Int64
  end : Int64
  attributes : Array[(String, Value)]
  events : Array[Event]
  links : Array[Link]
  status : Status
  dropped : Dropped
} derive(Eq, Debug)

///|
pub extend SpanData with Eq::{equal, not_equal}

///|
pub extend SpanData with Debug::{to_repr}

///|
/// Whether this span carries the `sampled` bit, which is the one thing a sink
/// needs in order to choose between exporting and merely counting.
pub fn SpanData::sampled(self : SpanData) -> Bool {
  self.context.sampled()
}

///|
/// How long the span lasted, in nanoseconds. Negative only if the caller handed in
/// an end before the start, which is left as it came.
pub fn SpanData::duration(self : SpanData) -> Int64 {
  self.end - self.start
}

///|
/// The span a caller holds: an identity fixed at creation, and fields that fill in
/// until it is finished.
///
/// Everything that changes after creation sits behind a `Ref`, so one span may be
/// filled in from the task that opened it and read from another. A non-recording
/// span — one the sampler dropped — accepts the same calls and forgets them, which
/// is what lets instrumented code stay the same whatever the sampler decided.
pub struct Span {
  context : TraceContext
  parent : Bytes?
  kind : SpanKind
  start : Int64
  recording : Bool
  sink : &Sink
  limits : Limits
  span_name : Ref[String]
  attribute_list : Ref[Array[(String, Value)]]
  event_list : Ref[Array[Event]]
  link_list : Ref[Array[Link]]
  span_status : Ref[Status]
  end_time : Ref[Int64?]
  dropped : Ref[Dropped]
}

///|
/// The identity of the span. It does not change for the span's whole life and
/// stays usable after it ends, because a later span may still name this one as its
/// parent.
pub fn Span::context(self : Span) -> TraceContext {
  self.context
}

///|
/// Whether the span is collecting anything: false after it ends, and false for a
/// span the sampler dropped. Instrumented code can use it to skip building
/// expensive attributes.
pub fn Span::is_recording(self : Span) -> Bool {
  self.recording && self.end_time.val is None
}

///|
/// Whether the span has been finished. A finished span takes no more writes and is
/// not handed to the sink a second time.
pub fn Span::is_ended(self : Span) -> Bool {
  self.end_time.val is Some(_)
}

///|
/// The name the span carries now, which `set_name` may have changed since it
/// started.
pub fn Span::name(self : Span) -> String {
  self.span_name.val
}

///|
/// A copy of the attributes set so far, in the order their keys first appeared.
pub fn Span::attributes(self : Span) -> Array[(String, Value)] {
  self.attribute_list.val.copy()
}

///|
/// A copy of the events added so far, in the order they were added.
pub fn Span::events(self : Span) -> Array[Event] {
  self.event_list.val.copy()
}

///|
/// A copy of the links added so far.
pub fn Span::links(self : Span) -> Array[Link] {
  self.link_list.val.copy()
}

///|
pub fn Span::status(self : Span) -> Status {
  self.span_status.val
}

///|
/// Set one attribute. A key already present is overwritten in place, so the
/// attribute list keeps the order in which keys first appeared rather than the
/// order of their last write.
///
/// Past the attribute limit the write is dropped and counted rather than applied: a
/// span with a runaway loop of attributes must not take the process down with it.
pub fn Span::set_attribute(self : Span, key : String, value : Value) -> Unit {
  self.set_attributes([(key, value)])
}

///|
/// Set several attributes at once, each following the same rule as
/// `set_attribute`.
pub fn Span::set_attributes(
  self : Span,
  attributes : Array[(String, Value)],
) -> Unit {
  guard self.is_recording() else { return }
  let kept = self.attribute_list.val
  let mut dropped = self.dropped.val
  for attribute in attributes {
    let value = truncate(attribute.1, self.limits.attribute_value_length)
    let mut at = None
    for i, existing in kept {
      if existing.0 == attribute.0 {
        at = Some(i)
        break
      }
    }
    match at {
      // Replacing an attribute is not a new attribute: the count does not move.
      Some(i) => kept[i] = (attribute.0, value)
      None =>
        if kept.length() < self.limits.attributes {
          kept.push((attribute.0, value))
        } else {
          dropped = { ..dropped, attributes: dropped.attributes + 1, }
        }
    }
  }
  self.dropped.val = dropped
}

///|
/// Add an event. `at` is the moment the caller says it happened, so a span recorded
/// after the fact keeps its real timeline.
pub fn Span::add_event(
  self : Span,
  name : String,
  attributes~ : Array[(String, Value)] = [],
  at~ : Int64,
) -> Unit {
  guard self.is_recording() else { return }
  let events = self.event_list.val
  if events.length() >= self.limits.events {
    let dropped = self.dropped.val
    self.dropped.val = { ..dropped, events: dropped.events + 1, }
    return
  }
  let kept : Array[(String, Value)] = []
  for attribute in attributes {
    if kept.length() >= self.limits.attributes_per_event {
      break
    }
    kept.push(
      (attribute.0, truncate(attribute.1, self.limits.attribute_value_length)),
    )
  }
  events.push({ name, at, attributes: kept, })
}

///|
/// Record an error the way OpenTelemetry's exception conventions ask: an event
/// named `exception` carrying `exception.type`, `exception.message` and
/// `exception.stacktrace`, with any `attributes` of the caller's own taking
/// precedence over those three.
pub fn Span::record_exception(
  self : Span,
  message~ : String,
  at~ : Int64,
  type_~ : String = "",
  stacktrace~ : String = "",
  attributes~ : Array[(String, Value)] = [],
) -> Unit {
  let own : Array[(String, Value)] = []
  if type_ != "" {
    own.push(("exception.type", Str(type_)))
  }
  own.push(("exception.message", Str(message)))
  if stacktrace != "" {
    own.push(("exception.stacktrace", Str(stacktrace)))
  }
  // The caller's own attributes take precedence over the conventional three, so a
  // key given twice ends up with the caller's value rather than doubled.
  for attribute in attributes {
    let mut at = None
    for i, existing in own {
      if existing.0 == attribute.0 {
        at = Some(i)
        break
      }
    }
    match at {
      Some(i) => own[i] = attribute
      None => own.push(attribute)
    }
  }
  self.add_event("exception", attributes=own, at~)
}

///|
/// Set the status, judged against the order `Ok` above `Error` above `Unset`:
/// `Unset` changes nothing, `Ok` is final, and a later `Error` replaces an earlier
/// one so the message can improve.
pub fn Span::set_status(self : Span, status : Status) -> Unit {
  guard self.is_recording() else { return }
  let current = self.span_status.val
  self.span_status.val = match (current, status) {
    (Ok, _) => Ok
    (_, Unset) => current
    _ => status
  }
}

///|
/// Rename the span. The sampler has already decided, so a better name found during
/// the request cannot change that decision — it changes what the backend draws.
pub fn Span::set_name(self : Span, name : String) -> Unit {
  guard self.is_recording() else { return }
  self.span_name.val = name
}

///|
/// Add a link to another span after creation, past the link limit being counted
/// rather than applied.
pub fn Span::add_link(self : Span, link : Link) -> Unit {
  guard self.is_recording() else { return }
  let links = self.link_list.val
  if links.length() >= self.limits.links {
    let dropped = self.dropped.val
    self.dropped.val = { ..dropped, links: dropped.links + 1, }
    return
  }
  links.push(link)
}

///|
/// Finish the span at `at`, handing it to the sink once.
///
/// Finishing twice does nothing the second time, and finishing a span the sampler
/// dropped hands nothing over. Child spans are untouched: they may still be
/// running, and they keep naming this one as their parent.
pub fn Span::finish(self : Span, at~ : Int64) -> Unit {
  guard self.end_time.val is None else { return }
  self.end_time.val = Some(at)
  guard self.recording else { return }
  self.sink.accept({
    context: self.context,
    parent: self.parent,
    name: self.span_name.val,
    kind: self.kind,
    start: self.start,
    end: at,
    attributes: self.attribute_list.val.copy(),
    events: self.event_list.val.copy(),
    links: self.link_list.val.copy(),
    status: self.span_status.val,
    dropped: self.dropped.val,
  })
}

// ------------------------------------------------------------------ internals

///|
/// A string attribute longer than the limit is cut to it, counting each character
/// as one, as OpenTelemetry's attribute limits ask. Every other type passes
/// through: an integer has nothing to truncate.
fn truncate(value : Value, limit : Int32?) -> Value {
  match (value, limit) {
    (Str(s), Some(n)) if s.length() > n =>
      Str(s.exact_view(start=0, end=n).to_owned())
    (Strs(xs), Some(n)) =>
      Strs(
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

///|
fn Span::new(
  context : TraceContext,
  parent : Bytes?,
  kind : SpanKind,
  start : Int64,
  name : String,
  recording : Bool,
  sink : &Sink,
  limits : Limits,
) -> Span {
  {
    context,
    parent,
    kind,
    start,
    recording,
    sink,
    limits,
    span_name: Ref(name),
    attribute_list: Ref([]),
    event_list: Ref([]),
    link_list: Ref([]),
    span_status: Ref(Unset),
    end_time: Ref(None),
    dropped: Ref(dropped_nothing),
  }
}

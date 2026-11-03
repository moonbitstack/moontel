// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a hop takes out of a set of request headers: the trace it joins, if the
/// request carried one, and the baggage that came with it.
///
/// One value rather than two calls, because a hop that reads one and forgets the
/// other is a bug this shape makes hard to write: `inject` puts back exactly what
/// `extract` found, changed only where the caller changed it.
pub(all) struct Extracted {
  /// The parent context, or `None` when the request carried no context or carried
  /// one this library refused. A refused context is not an error here: W3C Trace
  /// Context says a hop starts a new trace rather than failing the request.
  context : @trace.TraceContext?
  baggage : Baggage
} derive(Eq, Debug)

///|
pub extend Extracted with Eq::{equal, not_equal}

///|
pub extend Extracted with Debug::{to_repr}

///|
/// Read the propagation headers out of `headers`, which is the shape both an ASGI
/// scope and an outgoing request carry.
///
/// Header names are matched without regard to case; a value is taken as it is,
/// with the whitespace around it dropped.
///
/// Two `traceparent` headers refuse each other: the specification says a request
/// with more than one is invalid, and picking one of the two would be guessing
/// which proxy wrote the one that matters. Several `tracestate` or `baggage`
/// headers are combined in order, as RFC 7230 allows a field to be split across
/// lines.
///
/// A header that does not parse leaves that field empty and the rest intact: a
/// mangled `tracestate` must not cost a hop the trace, and a mangled `baggage`
/// must not cost it the trace either.
pub fn extract(headers : Array[(String, String)]) -> Extracted {
  let parents = values(headers, traceparent_header)
  let context = if parents.length() == 1 {
    let states = values(headers, tracestate_header)
    let state = if states.is_empty() { None } else { Some(join(states)) }
    join_trace(parents[0][:], state)
  } else {
    None
  }
  let carried = values(headers, baggage_header)
  let baggage = read_baggage(carried)
  { context, baggage, }
}

///|
/// Put `extracted` back into `headers`: the propagation headers already there are
/// removed and rewritten from the context and the bag, and everything else is left
/// exactly as it was.
///
/// Rewriting rather than appending is what makes this safe to call on a request
/// that already carried a context — the one from the sender must not survive next
/// to the one this hop decided on.
pub fn inject(
  headers : Array[(String, String)],
  extracted : Extracted,
) -> Array[(String, String)] {
  let out = headers.filter(header => !is_propagation_header(header.0))
  match extracted.context {
    Some(context) if context.is_valid() => {
      out.push((traceparent_header, context.to_traceparent()))
      if !context.state.is_empty() {
        out.push((tracestate_header, context.state.to_header()))
      }
    }
    _ => ()
  }
  if !extracted.baggage.is_empty() {
    out.push((baggage_header, extracted.baggage.to_header()))
  }
  out
}

///|
/// The context `traceparent` names, with the vendor state `tracestate` carries if
/// that header is readable.
///
/// The two are read separately because W3C Trace Context §3.3.1 says a `tracestate`
/// that fails to parse must not affect the `traceparent`: a hop that dropped the
/// trace over a mangled vendor header would break the one thing the header exists
/// to protect. A `traceparent` that fails, on the other hand, leaves no trace to
/// join, and the caller starts a new one rather than failing the request.
fn join_trace(
  traceparent : StringView,
  tracestate : String?,
) -> @trace.TraceContext? {
  let context = parse_traceparent(traceparent) catch { _ => return None }
  let state = match tracestate {
    None => @trace.empty_trace_state
    Some(text) =>
      @trace.TraceState::parse(text[:]) catch {
        _ => @trace.empty_trace_state
      }
  }
  Some({ ..context, state, })
}

///|
/// The bag the `baggage` field lines describe, or an empty one when the header is
/// refused.
fn read_baggage(carried : Array[String]) -> Baggage {
  if carried.is_empty() {
    return empty_baggage
  }
  let baggage = Baggage::parse(join(carried)[:]) catch {
    _ => return empty_baggage
  }
  baggage
}

///|
/// Whether `name` is one of the three headers this package owns.
fn is_propagation_header(name : String) -> Bool {
  let name = name.to_lower()
  name == traceparent_header ||
  name == tracestate_header ||
  name == baggage_header
}

///|
/// Every value of `name` in `headers`, in order, matched without regard to case.
fn values(headers : Array[(String, String)], name : String) -> Array[String] {
  let out : Array[String] = []
  for header in headers {
    if header.0.to_lower() == name {
      out.push(header.1)
    }
  }
  out
}

///|
/// Several field lines as one value, which is what RFC 7230 §3.2.2 says a repeated
/// header means.
fn join(parts : Array[String]) -> String {
  let out = StringBuilder()
  for i, part in parts {
    if i > 0 {
      out.write_char(',')
    }
    out.write_string(part)
  }
  out.to_string()
}

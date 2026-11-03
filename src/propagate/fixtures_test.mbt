// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A sixteen- or eight-octet id from its hexadecimal spelling.
fn hex(text : String) -> Bytes raise {
  @base16.decode(text)
}

///|
/// A source of randomness that counts, so a hop mints different ids every time
/// without a real generator behind it.
fn counting_rand() -> (Int32) -> Bytes {
  let calls = Ref(0)
  width => {
    calls.val = calls.val + 1
    let bytes : Array[Byte] = []
    for i in 0..<width {
      bytes.push(((calls.val * 31 + i + 1) % 251 + 1).to_byte())
    }
    Bytes::from_array(bytes)
  }
}

///|
/// One hop, as the interoperability suite drives it: the headers a request
/// arrived with in, the propagation headers the hop would send on out.
///
/// The span is started the way an application would start it and finished at once;
/// what the suite checks is the header, not the span.
fn hop(
  tracer : @trace.Tracer,
  headers : Array[(String, String)],
) -> Array[(String, String)] raise {
  let extracted = @propagate.extract(headers)
  let span = match extracted.context {
    Some(parent) => tracer.start("GET /", parent~, kind=@trace.Server, at=1L)
    None => tracer.start("GET /", kind=@trace.Server, at=1L)
  }
  let out = @propagate.inject([], {
    context: Some(span.context()),
    baggage: extracted.baggage,
  })
  span.finish(at=2L)
  out
}

///|
/// A tracer that keeps everything, with parent-based sampling over always-on.
fn hop_tracer() -> @trace.Tracer {
  @trace.Tracer::new(
    rand=counting_rand(),
    sink=@trace.Recorder::new(),
    sampler=@trace.parent_based(root=@trace.always),
  )
}

///|
/// The value of `name` in `headers`, if any.
fn header(headers : Array[(String, String)], name : String) -> String? {
  for entry in headers {
    if entry.0.to_lower() == name {
      return Some(entry.1)
    }
  }
  None
}

///|
/// The traceparent a hop sent on, parsed back.
fn traceparent_of(
  headers : Array[(String, String)],
) -> @trace.TraceContext raise {
  match header(headers, "traceparent") {
    Some(value) => @propagate.parse_traceparent(value[:])
    None => fail("the hop sent no traceparent")
  }
}

///|
/// The trace id a hop sent on, in hexadecimal, or "" when it sent none.
fn trace_id_of(headers : Array[(String, String)]) -> String raise {
  @base16.encode(traceparent_of(headers).trace_id[:])
}

///|
/// The span id a hop sent on, in hexadecimal.
fn span_id_of(headers : Array[(String, String)]) -> String raise {
  @base16.encode(traceparent_of(headers).span_id[:])
}

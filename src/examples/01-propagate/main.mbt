// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The two headers a hop reads and the three it writes, over the same carrier: an
/// array of name and value pairs, which is what an ASGI scope and an HTTP client's
/// header list both are.
///
///     moon run src/examples/01-propagate
#coverage.skip
fn main {
  let inbound = [
    ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
    ("tracestate", "vendor=abc"),
    ("baggage", "userId=alice,note=caf%C3%A9"),
    ("accept", "application/json"),
  ]
  println("inbound")
  for header in inbound {
    println("  \{header.0}: \{header.1}")
  }

  // What the hop understood: the trace to join, and the bag that came with it.
  let extracted = @propagate.extract(inbound)
  println("")
  println(
    match extracted.context {
      Some(context) => "joined trace \{context.to_traceparent()}"
      None => "no usable context, this hop starts a trace"
    },
  )
  println("baggage: \{extracted.baggage.to_header()}")

  // A span of this hop's own, under whatever context arrived.
  let tracer = @trace.Tracer::new(
    rand=random_bytes,
    sink=@trace.Recorder::new(),
    sampler=@trace.parent_based(root=@trace.always),
  )
  let span = match extracted.context {
    Some(parent) =>
      tracer.start("publish", parent~, kind=@trace.Client, at=1L) catch {
        _ => abort("the platform has no entropy source")
      }
    None =>
      tracer.start("publish", kind=@trace.Client, at=1L) catch {
        _ => abort("the platform has no entropy source")
      }
  }
  span.finish(at=2L)

  // The next request carries this hop's span as its parent, and the bag unchanged.
  let outgoing = @propagate.inject(inbound, {
    context: Some(span.context()),
    baggage: extracted.baggage,
  })
  println("")
  println("outgoing")
  for header in outgoing {
    println("  \{header.0}: \{header.1}")
  }
}

///|
fn random_bytes(width : Int32) -> Bytes {
  @moonseed.bytes(width, @system.source) catch {
    _ => abort("the platform has no entropy source")
  }
}

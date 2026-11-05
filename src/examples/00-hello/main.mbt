// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A tracer, a root span, a child span, some attributes and an event, and the two
/// spans as a sink receives them.
///
///     moon run src/examples/00-hello
#coverage.skip
fn main {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=random_bytes,
    sink=recorder,
    sampler=@trace.parent_based(root=@trace.always),
  )
  // Times are handed in: this library never reads a clock, so a batch job
  // replaying yesterday's events and a server under load use the same code.
  let started = 1_700_000_000_000_000_000L
  let root = tracer.start("GET /orders/{id}", kind=@trace.Server, at=started, attributes=[
    ("http.request.method", @trace.Str("GET")),
  ]) catch {
    _ => abort("the platform has no entropy source")
  }
  let child = tracer.start(
    "SELECT orders",
    parent=root.context(),
    kind=@trace.Client,
    at=started + 1_000_000L,
  ) catch {
    _ => abort("the platform has no entropy source")
  }
  child.set_attribute("db.rows", @trace.Int(3L))
  child.set_status(@trace.Ok)
  child.finish(at=started + 2_000_000L)

  root.add_event("cache.miss", at=started + 3_000_000L)
  root.set_attribute("http.response.status_code", @trace.Int(200L))
  root.finish(at=started + 4_000_000L)

  for span in recorder.spans() {
    println(
      "\{span.name}  \{span.context.to_traceparent()}  \{span.duration()} ns",
    )
    for pair in span.attributes {
      println("  \{pair.0} = \{pair.1}")
    }
    for event in span.events {
      println("  event \{event.name} at \{event.at}")
    }
  }
}

///|
/// Eight or sixteen octets from the platform's entropy source. A caller this close
/// to the edge is the one that knows what to do when there is none; here that is to
/// stop rather than to trace with predictable ids.
fn random_bytes(width : Int32) -> Bytes {
  @moonseed.bytes(width, @system.source) catch {
    _ => abort("the platform has no entropy source")
  }
}

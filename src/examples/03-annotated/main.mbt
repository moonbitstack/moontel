// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Finished spans, kept to print.
struct Kept {
  spans : Array[@trace.SpanData]
}

///|
impl @trace.Sink for Kept with fn accept(self, span) {
  self.spans.push(span)
}

///|
/// Bytes that never repeat, so ids are valid and the output is the same on every run.
fn counting() -> (Int32) -> Bytes {
  let mut next = 1
  fn(n) {
    Bytes::makei(n, _ => {
      next = next + 1
      (next % 251).to_byte()
    })
  }
}

///|
/// A clock that moves a millisecond every time it is read.
fn ticking() -> () -> Int64 {
  let mut at = 1_700_000_000_000_000_000L
  fn() {
    at = at + 1_000_000L
    at
  }
}

///|
fn run() -> Unit raise {
  let kept = { spans: [], }
  let tracer = @trace.Tracer::new(
    rand=counting(),
    sink=kept,
    sampler=@trace.always,
  )
  let now = ticking()
  ignore(place_traced(tracer, "tea", now~))
  ignore(place_traced(tracer, "gold", now~) catch { _ => 0 })
  for span in kept.spans {
    println(
      "\{span.name} \{span.status} attributes=\{span.attributes.length()} events=\{span.events.length()} \{span.end - span.start}ns",
    )
  }
}

///|
#coverage.skip
fn main {
  run() catch {
    e => println("refused: \{e}")
  }
}

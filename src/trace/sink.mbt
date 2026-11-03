// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Where finished spans go.
///
/// This is the one seam this library leaves open: exporting to OTLP, to a file, to
/// a ring buffer that a background task drains, or to nothing at all is the
/// caller's business, and the shapes that do it belong to whoever owns the
/// transport. A sink is called on the task that finished the span, so an
/// implementation that writes to a socket should hand the span to a queue rather
/// than block the request.
///
/// A sink receives every recorded span, including the ones the sampler dropped
/// from the trace: `SpanData::sampled` is the bit that separates "keep for
/// counting" from "send to the backend".
pub(open) trait Sink {
  fn accept(Self, SpanData) -> Unit
}

///|
/// Throws spans away. The default for a tracer whose owner has not decided where
/// they go yet, and the sink a test uses when it only cares that nothing crashes.
pub(all) struct Discard {}

///|
pub let discard : Discard = Discard::{ }

///|
pub impl Sink for Discard with fn accept(_, _) {

}

///|
pub extend Discard with Sink::{accept}

///|
/// Keeps spans in memory, in the order they finished.
///
/// Meant for tests, examples and the debugging of a single request; a service
/// wants a sink that ships spans off the process, because this one grows without
/// bound.
pub struct Recorder {
  spans : Ref[Array[SpanData]]
}

///|
pub fn Recorder::new() -> Recorder {
  { spans: Ref([]), }
}

///|
pub impl Sink for Recorder with fn accept(self, span) {
  self.spans.val.push(span)
}

///|
pub extend Recorder with Sink::{accept}

///|
/// The spans kept so far, oldest first.
pub fn Recorder::spans(self : Recorder) -> Array[SpanData] {
  self.spans.val.copy()
}

///|
/// How many spans are kept.
pub fn Recorder::len(self : Recorder) -> Int32 {
  self.spans.val.length()
}

///|
/// The spans kept so far, and an empty recorder afterwards. Use this when a test
/// drives several requests through one tracer and reads one request's spans at a
/// time.
pub fn Recorder::take(self : Recorder) -> Array[SpanData] {
  let taken = self.spans.val
  self.spans.val = []
  taken
}

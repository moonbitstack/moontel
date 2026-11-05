// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Where log records go.
///
/// The same seam the trace package leaves open, for the same reason: writing to a
/// console, to a file, to a collector over HTTP or to nothing at all is the
/// caller's business. A sink is called on the task that wrote the record, so an
/// implementation that talks to the network should queue rather than block.
pub(open) trait Sink {
  /// Take one record.
  fn accept(Self, LogRecord) -> Unit
}

///|
/// Throws records away. The sink a logger has before its owner has decided where
/// they go.
pub(all) struct Discard {}

///|
pub let discard : Discard = Discard::{ }

///|
pub impl Sink for Discard with fn accept(_, _) {

}

///|
pub extend Discard with Sink::{accept}

///|
/// Keeps records in memory, in the order they were written.
///
/// For tests, replays and the debugging of one request. A service wants a sink
/// that ships records off the process, because this one grows without bound.
pub struct Recorder {
  records : Ref[Array[LogRecord]]
}

///|
/// An empty recorder.
pub fn Recorder::new() -> Recorder {
  { records: Ref([]), }
}

///|
pub impl Sink for Recorder with fn accept(self, record) {
  self.records.val.push(record)
}

///|
pub extend Recorder with Sink::{accept}

///|
/// The records kept so far, oldest first.
pub fn Recorder::records(self : Recorder) -> Array[LogRecord] {
  self.records.val.copy()
}

///|
/// How many records are kept.
pub fn Recorder::len(self : Recorder) -> Int32 {
  self.records.val.length()
}

///|
/// The records kept so far, and an empty recorder afterwards.
pub fn Recorder::take(self : Recorder) -> Array[LogRecord] {
  let taken = self.records.val
  self.records.val = []
  taken
}

///|
/// Hands every record to each of several sinks, in the order they were given.
///
/// A program that wants a console line and an export of the same record writes the
/// line once and lets this do both; the sinks never learn about each other.
pub struct Fanout {
  sinks : Array[&Sink]
}

///|
/// One sink that writes to all of `sinks`.
pub fn Fanout::new(sinks~ : Array[&Sink]) -> Fanout {
  { sinks, }
}

///|
pub impl Sink for Fanout with fn accept(self, record) {
  for sink in self.sinks {
    sink.accept(record)
  }
}

///|
pub extend Fanout with Sink::{accept}

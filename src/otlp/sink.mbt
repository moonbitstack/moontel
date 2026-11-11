// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Where finished metrics go.
///
/// The trace and log packages leave the same seam open, and for the same reason:
/// printing a point, keeping it in memory and posting it to a collector are the
/// caller's business. A metric is a whole family — a name, its kind and every
/// series under it — so one call carries all of it, and an implementation that
/// talks to the network should queue rather than block.
pub(open) trait MetricSink {
  /// Take one metric.
  fn accept(Self, Metric) -> Unit
}

///|
/// The exporter is a sink: a program that instruments with the meter hands it the
/// same exporter it already uses for spans and logs, and no second queue appears.
pub impl MetricSink for MetricsExporter with fn accept(self, metric) {
  self.record(metric)
}

///|
pub extend MetricsExporter with MetricSink::{accept}

///|
/// Keeps metrics in memory, in the order they arrived.
///
/// For tests and for a program that wants to inspect a collection before it
/// decides where to send it. A service wants a sink that ships the points off the
/// process, because this one grows without bound.
pub struct MetricRecorder {
  metrics : Ref[Array[Metric]]
}

///|
/// An empty recorder.
pub fn MetricRecorder::new() -> MetricRecorder {
  { metrics: Ref([]), }
}

///|
pub impl MetricSink for MetricRecorder with fn accept(self, metric) {
  self.metrics.val.push(metric)
}

///|
pub extend MetricRecorder with MetricSink::{accept}

///|
/// The metrics kept so far, oldest first.
pub fn MetricRecorder::metrics(self : MetricRecorder) -> Array[Metric] {
  self.metrics.val.copy()
}

///|
/// How many metrics are kept.
pub fn MetricRecorder::len(self : MetricRecorder) -> Int32 {
  self.metrics.val.length()
}

///|
/// The metrics kept so far, and an empty recorder afterwards.
pub fn MetricRecorder::take(self : MetricRecorder) -> Array[Metric] {
  let taken = self.metrics.val
  self.metrics.val = []
  taken
}

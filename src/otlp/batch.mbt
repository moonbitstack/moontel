// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How much telemetry one request carries and how long a record may wait.
///
/// The numbers are the OpenTelemetry SDK's batch processor defaults: a queue of
/// 2048, at most 512 records per request, a request every five seconds, and thirty
/// seconds for one request to complete. They are sized for a service that would
/// rather lose telemetry than memory, which is why an overfull queue drops the
/// newest record and counts it.
#derive(Eq, Debug)
pub(all) struct BatchPolicy {
  queue_limit : Int32
  batch : Int32
  delay : Int64
  timeout : Int64
}

///|
pub extend BatchPolicy with Eq::{equal, not_equal}

///|
pub extend BatchPolicy with Debug::{to_repr}

///|
/// The defaults, from the SDK specification's batch processor table.
pub let otlp_batch : BatchPolicy = {
  queue_limit: 2048,
  batch: 512,
  delay: 5000L,
  timeout: 30000L,
}

///|
/// A policy with any of the four values changed.
pub fn BatchPolicy::new(
  queue_limit~ : Int32 = otlp_batch.queue_limit,
  batch~ : Int32 = otlp_batch.batch,
  delay~ : Int64 = otlp_batch.delay,
  timeout~ : Int64 = otlp_batch.timeout,
) -> BatchPolicy {
  { queue_limit, batch, delay, timeout, }
}

///|
/// Records waiting to be sent, and how many were refused because the queue was
/// full.
///
/// A record is pushed on the task that produced it and taken by the task that
/// exports, so the two never block each other: a full queue drops rather than
/// waits, because telemetry that costs a request its latency is worse than
/// telemetry that is missing.
pub struct Batch[T] {
  items : Ref[Array[T]]
  since : Ref[Int64]
  policy : BatchPolicy
  dropped : Ref[Int32]
}

///|
/// An empty queue following `policy`.
pub fn[T] Batch::new(policy~ : BatchPolicy = otlp_batch) -> Batch[T] {
  { items: Ref([]), since: Ref(0L), policy, dropped: Ref(0), }
}

///|
/// Add one record, arriving at `at`. A full queue refuses it and counts it.
pub fn[T] Batch::push(self : Batch[T], item : T, at~ : Int64) -> Unit {
  let items = self.items.val
  if items.length() >= self.policy.queue_limit {
    self.dropped.val = self.dropped.val + 1
    return
  }
  if items.is_empty() {
    self.since.val = at
  }
  items.push(item)
}

///|
/// How many records are waiting.
pub fn[T] Batch::len(self : Batch[T]) -> Int32 {
  self.items.val.length()
}

///|
/// How many records the queue refused since it was made.
pub fn[T] Batch::dropped(self : Batch[T]) -> Int32 {
  self.dropped.val
}

///|
/// What is ready to send at `at`: a full batch whatever the clock says, otherwise
/// everything that has waited the whole delay, and nothing before either.
pub fn[T] Batch::due(self : Batch[T], at~ : Int64) -> Array[T] {
  let items = self.items.val
  if items.is_empty() {
    return []
  }
  if items.length() >= self.policy.batch ||
    at - self.since.val >= self.policy.delay {
    return self.take(self.policy.batch, at)
  }
  []
}

///|
/// Everything waiting, however recently it arrived. This is what a forced flush
/// sends.
pub fn[T] Batch::take_all(self : Batch[T], at~ : Int64) -> Array[T] {
  self.take(self.items.val.length(), at)
}

///|
/// At most `count` records, oldest first, leaving the rest queued.
fn[T] Batch::take(self : Batch[T], count : Int32, at : Int64) -> Array[T] {
  let items = self.items.val
  let n = if count < items.length() { count } else { items.length() }
  let taken : Array[T] = []
  let rest : Array[T] = []
  for i, item in items {
    if i < n {
      taken.push(item)
    } else {
      rest.push(item)
    }
  }
  self.items.val = rest
  // Whatever is left has waited at least as long as what was taken, so the clock
  // for the next batch starts here rather than at its own arrival: it will not be
  // held back by the wait it has already served.
  if !rest.is_empty() {
    self.since.val = at
  }
  taken
}

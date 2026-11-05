// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What one flush did, counted in records.
///
/// `delivered` and `rejected` are what the server took and what it said it would
/// not; `dropped` is what this side gave up on, because the queue was full or the
/// attempts ran out; `attempts` is how many requests were made, which is the only
/// way a test can see that a retry happened at all.
#derive(Eq, Debug)
pub(all) struct Report {
  delivered : Int32
  rejected : Int32
  dropped : Int32
  attempts : Int32
}

///|
pub extend Report with Eq::{equal, not_equal}

///|
pub extend Report with Debug::{to_repr}

///|
/// Everything one exporter has done since it was made.
#derive(Eq, Debug)
pub(all) struct Stats {
  delivered : Int64
  rejected : Int64
  dropped : Int64
  refused : Int64
  requests : Int64
}

///|
pub extend Stats with Eq::{equal, not_equal}

///|
pub extend Stats with Debug::{to_repr}

///|
/// Nothing sent yet.
pub let no_stats : Stats = {
  delivered: 0L,
  rejected: 0L,
  dropped: 0L,
  refused: 0L,
  requests: 0L,
}

///|
/// The part of an exporter that does not depend on which signal it carries:
/// the queue, the request, the retry rules and the clock.
///
/// One engine for the three signals, because they differ only in their path and
/// their body: three copies of the retry loop would be three places for the
/// `Retry-After` rule to drift.
pub struct Outbox[T] {
  transport : &Transport
  url : String
  headers : Array[(String, String)]
  encode : (Array[T]) -> String
  policy : BatchPolicy
  backoff : Backoff
  attempts : Int32
  pause : async (Int64) -> Unit
  now : () -> Int64
  rand : (Int32) -> Bytes
  batch : Batch[T]
  lock : @async.Mutex
  stats : Ref[Stats]
}

///|
fn[T] Outbox::enqueue(self : Outbox[T], item : T) -> Unit {
  self.batch.push(item, at=(self.now)())
}

///|
fn[T] Outbox::waiting(self : Outbox[T]) -> Int32 {
  self.batch.len()
}

///|
fn[T] Outbox::stats(self : Outbox[T]) -> Stats {
  {
    ..self.stats.val,
    refused: self.stats.val.refused + self.batch.dropped().to_int64(),
  }
}

///|
/// Send everything waiting, however recently it arrived.
async fn[T] Outbox::flush_all(self : Outbox[T]) -> Report {
  self.lock.acquire()
  let items = self.batch.take_all(at=(self.now)())
  let report = self.send_all(items)
  self.lock.release()
  report
}

///|
/// Send what the batching policy says is due, which is nothing when the queue is
/// young and short.
async fn[T] Outbox::flush_due(self : Outbox[T]) -> Report {
  self.lock.acquire()
  let items = self.batch.due(at=(self.now)())
  let report = self.send_all(items)
  self.lock.release()
  report
}

///|
async fn[T] Outbox::send_all(self : Outbox[T], items : Array[T]) -> Report {
  let mut report : Report = {
    delivered: 0,
    rejected: 0,
    dropped: 0,
    attempts: 0,
  }
  if items.is_empty() {
    return report
  }
  let size = self.policy.batch
  let mut index = 0
  while index < items.length() {
    let chunk : Array[T] = []
    let mut taken = 0
    while index < items.length() && taken < size {
      chunk.push(items[index])
      index = index + 1
      taken = taken + 1
    }
    let part = self.send_one(chunk)
    report = {
      delivered: report.delivered + part.delivered,
      rejected: report.rejected + part.rejected,
      dropped: report.dropped + part.dropped,
      attempts: report.attempts + part.attempts,
    }
  }
  report
}

///|
/// One request, retried as the protocol allows.
///
/// The loop ends on an acceptance, on a refusal retrying cannot fix, when the
/// attempt budget runs out, or when the next wait would overrun the export
/// timeout — the specification requires those bounds, and a service that is
/// shutting down should not be held by a collector that is not answering.
async fn[T] Outbox::send_one(self : Outbox[T], chunk : Array[T]) -> Report {
  let count = chunk.length()
  let mut report : Report = {
    delivered: 0,
    rejected: 0,
    dropped: 0,
    attempts: 0,
  }
  if count == 0 {
    return report
  }
  let request : Request = {
    url: self.url,
    headers: self.headers,
    body: (self.encode)(chunk),
  }
  let deadline = (self.now)() + self.policy.timeout
  let mut pending = true
  while pending {
    report = { ..report, attempts: report.attempts + 1, }
    let answer = Ok(self.transport.send(request)) catch { error => Err(error) }
    let wait = match answer {
      Ok(reply) =>
        match verdict(reply.status) {
          Accepted => {
            let rejected = reply.rejected().unwrap_or(0)
            report = {
              ..report,
              delivered: report.delivered + count - rejected,
              rejected: report.rejected + rejected,
            }
            None
          }
          Rejected => {
            report = { ..report, rejected: report.rejected + count, }
            None
          }
          Retry => Some(self.backoff_wait(reply, report.attempts))
        }
      // No reply at all: the connection failed or the server hung up, and the
      // protocol says to come back with the same request.
      Err(_) => Some(self.backoff.delay(report.attempts, self.rand))
    }
    match wait {
      None => pending = false
      Some(wait) =>
        if report.attempts >= self.attempts || (self.now)() + wait > deadline {
          report = { ..report, dropped: report.dropped + count, }
          pending = false
        } else {
          (self.pause)(wait)
        }
    }
  }
  let stats = self.stats.val
  self.stats.val = {
    delivered: stats.delivered + report.delivered.to_int64(),
    rejected: stats.rejected + report.rejected.to_int64(),
    dropped: stats.dropped + report.dropped.to_int64(),
    refused: stats.refused,
    requests: stats.requests + 1L,
  }
  report
}

///|
/// The wait before the next attempt: what the server asked for when it asked, and
/// this library's own backoff when it did not.
fn[T] Outbox::backoff_wait(
  self : Outbox[T],
  reply : Reply,
  attempt : Int32,
) -> Int64 {
  match reply.retry_after(now=(self.now)()) {
    // Every exporter in a fleet is told the same thing by the same header, so a
    // wait the server named is used as it stands: jitter would only make this
    // client early.
    Some(wait) => wait
    None => self.backoff.delay(attempt, self.rand)
  }
}

///|
/// The default retry wait: the caller's own task, asleep.
async fn pause_milliseconds(milliseconds : Int64) -> Unit {
  @async.sleep(milliseconds.to_int())
}

///|
/// The URL a signal is posted to. A trailing slash on the endpoint is the caller's
/// habit rather than an error, so it does not become a double slash in the path.
fn signal_url(endpoint : String, path : String) -> String {
  if endpoint.has_suffix("/") {
    endpoint.exact_view(start=0, end=endpoint.length() - 1).to_owned() + path
  } else {
    endpoint + path
  }
}

///|
/// Span export: a `@trace.Sink` that queues what the tracer finishes and posts it
/// to `/v1/traces`.
///
/// The sink answers immediately, so a request never waits for a collector; the
/// request itself happens on whichever task calls `flush` or `run`.
pub struct TraceExporter {
  outbox : Outbox[@trace.SpanData]
}

///|
/// An exporter posting spans to `endpoint` (`http://localhost:4318` is the
/// protocol's default) through `transport`.
///
/// `headers` is where authentication goes: an API key for a hosted backend, an
/// organisation and a project for one that wants them. `resource` describes the
/// program and is sent with every request.
pub fn TraceExporter::new(
  transport~ : &Transport,
  endpoint~ : String = "http://localhost:4318",
  headers~ : Array[(String, String)] = [],
  resource~ : Resource = unknown_service,
  scope~ : Scope = moonbit_scope,
  policy~ : BatchPolicy = otlp_batch,
  backoff~ : Backoff = otlp_backoff,
  attempts~ : Int32 = 5,
  now~ : () -> Int64,
  rand~ : (Int32) -> Bytes,
  pause~ : async (Int64) -> Unit = pause_milliseconds,
) -> TraceExporter {
  let encode = fn(spans : Array[@trace.SpanData]) {
    encode_traces(spans, resource~, scope~)
  }
  {
    outbox: {
      transport,
      url: signal_url(endpoint, "/v1/traces"),
      headers: with_content_type(headers),
      encode,
      policy,
      backoff,
      attempts,
      pause,
      now,
      rand,
      batch: Batch::new(policy~),
      lock: @async.Mutex::Mutex(),
      stats: Ref(no_stats),
    },
  }
}

///|
/// Queue one finished span. A span the sampler dropped is not exported: its sink
/// call is what keeps its counts, not what ships it.
pub impl @trace.Sink for TraceExporter with fn accept(self, span) {
  if span.sampled() {
    self.outbox.enqueue(span)
  }
}

///|
pub extend TraceExporter with @trace.Sink::{accept}

///|
/// How many spans are waiting.
pub fn TraceExporter::waiting(self : TraceExporter) -> Int32 {
  self.outbox.waiting()
}

///|
/// What this exporter has done so far.
pub fn TraceExporter::stats(self : TraceExporter) -> Stats {
  self.outbox.stats()
}

///|
/// Send everything queued and wait for the requests to finish.
pub async fn TraceExporter::flush(self : TraceExporter) -> Report {
  self.outbox.flush_all()
}

///|
/// Send what is due now.
pub async fn TraceExporter::tick(self : TraceExporter) -> Report {
  self.outbox.flush_due()
}

///|
/// Keep the exporter running: wake every `policy.delay`, send what is due, and
/// never return.
///
/// A program starts this in its own task and lets its task group cancel it on the
/// way out; the last flush belongs to the shutdown path, where the caller can wait
/// for it.
pub async fn TraceExporter::run(self : TraceExporter) -> Unit {
  while true {
    @async.sleep(self.outbox.policy.delay.to_int())
    self.outbox.flush_due() |> ignore
  }
}

///|
/// Log export: a `@log.Sink` that queues records and posts them to `/v1/logs`.
pub struct LogsExporter {
  outbox : Outbox[@log.LogRecord]
}

///|
/// An exporter posting log records to `endpoint`.
pub fn LogsExporter::new(
  transport~ : &Transport,
  endpoint~ : String = "http://localhost:4318",
  headers~ : Array[(String, String)] = [],
  resource~ : Resource = unknown_service,
  scope~ : Scope = moonbit_scope,
  policy~ : BatchPolicy = otlp_batch,
  backoff~ : Backoff = otlp_backoff,
  attempts~ : Int32 = 5,
  now~ : () -> Int64,
  rand~ : (Int32) -> Bytes,
  pause~ : async (Int64) -> Unit = pause_milliseconds,
) -> LogsExporter {
  let encode = fn(records : Array[@log.LogRecord]) {
    encode_logs(records, resource~, scope~)
  }
  {
    outbox: {
      transport,
      url: signal_url(endpoint, "/v1/logs"),
      headers: with_content_type(headers),
      encode,
      policy,
      backoff,
      attempts,
      pause,
      now,
      rand,
      batch: Batch::new(policy~),
      lock: @async.Mutex::Mutex(),
      stats: Ref(no_stats),
    },
  }
}

///|
pub impl @log.Sink for LogsExporter with fn accept(self, record) {
  self.outbox.enqueue(record)
}

///|
pub extend LogsExporter with @log.Sink::{accept}

///|
/// How many records are waiting.
pub fn LogsExporter::waiting(self : LogsExporter) -> Int32 {
  self.outbox.waiting()
}

///|
/// What this exporter has done so far.
pub fn LogsExporter::stats(self : LogsExporter) -> Stats {
  self.outbox.stats()
}

///|
/// Send everything queued.
pub async fn LogsExporter::flush(self : LogsExporter) -> Report {
  self.outbox.flush_all()
}

///|
/// Send what is due now.
pub async fn LogsExporter::tick(self : LogsExporter) -> Report {
  self.outbox.flush_due()
}

///|
/// Keep the exporter running, waking every `policy.delay`.
pub async fn LogsExporter::run(self : LogsExporter) -> Unit {
  while true {
    @async.sleep(self.outbox.policy.delay.to_int())
    self.outbox.flush_due() |> ignore
  }
}

///|
/// Metric export: posts what a collector hands it to `/v1/metrics`.
///
/// There is no meter in this package. A producer that already keeps metrics — the
/// one in `otlp/p8s` reads a snapshot of them — hands the exporter the metrics to
/// send, so this library never becomes a second place where a counter lives.
pub struct MetricsExporter {
  outbox : Outbox[Metric]
}

///|
/// An exporter posting metrics to `endpoint`.
pub fn MetricsExporter::new(
  transport~ : &Transport,
  endpoint~ : String = "http://localhost:4318",
  headers~ : Array[(String, String)] = [],
  resource~ : Resource = unknown_service,
  scope~ : Scope = moonbit_scope,
  policy~ : BatchPolicy = otlp_batch,
  backoff~ : Backoff = otlp_backoff,
  attempts~ : Int32 = 5,
  now~ : () -> Int64,
  rand~ : (Int32) -> Bytes,
  pause~ : async (Int64) -> Unit = pause_milliseconds,
) -> MetricsExporter {
  let encode = fn(metrics : Array[Metric]) {
    encode_metrics(metrics, resource~, scope~)
  }
  {
    outbox: {
      transport,
      url: signal_url(endpoint, "/v1/metrics"),
      headers: with_content_type(headers),
      encode,
      policy,
      backoff,
      attempts,
      pause,
      now,
      rand,
      batch: Batch::new(policy~),
      lock: @async.Mutex::Mutex(),
      stats: Ref(no_stats),
    },
  }
}

///|
/// Queue one metric. A metric is a whole family — a name, its kind and all of its
/// points — so one call carries every series that shares a name.
pub fn MetricsExporter::record(self : MetricsExporter, metric : Metric) -> Unit {
  self.outbox.enqueue(metric)
}

///|
/// How many metrics are waiting.
pub fn MetricsExporter::waiting(self : MetricsExporter) -> Int32 {
  self.outbox.waiting()
}

///|
/// What this exporter has done so far.
pub fn MetricsExporter::stats(self : MetricsExporter) -> Stats {
  self.outbox.stats()
}

///|
/// Send everything queued.
pub async fn MetricsExporter::flush(self : MetricsExporter) -> Report {
  self.outbox.flush_all()
}

///|
/// Send what is due now.
pub async fn MetricsExporter::tick(self : MetricsExporter) -> Report {
  self.outbox.flush_due()
}

///|
/// Keep the exporter running, waking every `policy.delay`.
pub async fn MetricsExporter::run(self : MetricsExporter) -> Unit {
  while true {
    @async.sleep(self.outbox.policy.delay.to_int())
    self.outbox.flush_due() |> ignore
  }
}

///|
/// The caller's headers with the content type this body needs, replacing one that
/// was already there: a JSON body announced as protobuf is refused by the server
/// that reads the header first.
fn with_content_type(
  headers : Array[(String, String)],
) -> Array[(String, String)] {
  let out = headers.filter(header => header.0.to_lower() != "content-type")
  out.push(("Content-Type", "application/json"))
  out
}

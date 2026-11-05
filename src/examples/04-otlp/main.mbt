// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// All three signals leaving the process over OTLP/HTTP: a server span with an
/// event, two log records written inside it, and a counter and a histogram turned
/// into OTLP metrics.
///
///     moon run src/examples/04-otlp --target native
///     moon run src/examples/04-otlp --target native -- http://localhost:4318
///     moon run src/examples/04-otlp --target native -- http://localhost:4318 gzip
///
/// With an endpoint on the command line the program requires the collector to be
/// there: it exits non-zero when the batch could not be delivered, which is what
/// the conformance job in CI runs. Without one it talks to the protocol's default
/// address and reports what happened, so running the examples one after another
/// stays useful on a machine with no collector.
///
/// `gzip` after the endpoint compresses every request body and says so. It is the
/// one thing a client may do to a request that the protocol leaves open, and the
/// conformance job runs the example both ways.
#coverage.skip
async fn main {
  let arguments = @env.args()
  let endpoint = if arguments.length() > 1 {
    arguments[1]
  } else {
    "http://localhost:4318"
  }
  let required = arguments.length() > 1
  // With no collector named there is nothing to retry against, so one attempt says
  // whether something is listening without spending half a minute finding out.
  let attempts = if required { 5 } else { 1 }
  let compression = if arguments.length() > 2 && arguments[2] == "gzip" {
    @http.Compression::Gzip
  } else {
    @http.Compression::Plain
  }
  let transport = @http.HttpTransport::new(compression~)
  let started = 1_700_000_000_000_000_000L

  // One exporter per signal. They share the transport and the resource, and each
  // batches and retries on its own.
  let traces = @otlp.TraceExporter::new(
    transport~,
    endpoint~,
    resource=@otlp.Resource::of_service("moontel-example").with_attribute(
      "deployment.environment.name",
      @trace.Str("test"),
    ),
    now=millis,
    rand=random_bytes,
    attempts~,
  )
  let logs = @otlp.LogsExporter::new(
    transport~,
    endpoint~,
    resource=@otlp.Resource::of_service("moontel-example"),
    now=millis,
    rand=random_bytes,
    attempts~,
  )
  let metrics = @otlp.MetricsExporter::new(
    transport~,
    endpoint~,
    resource=@otlp.Resource::of_service("moontel-example"),
    now=millis,
    rand=random_bytes,
    attempts~,
  )

  // A span the sampler keeps, with one child and one event on it.
  let tracer = @trace.Tracer::new(
    sink=traces,
    rand=random_bytes,
    sampler=@trace.parent_based(root=@trace.always),
  )
  let span = tracer.start("GET /orders/42", kind=@trace.Server, at=started, attributes=[
    ("http.request.method", @trace.Str("GET")),
  ]) catch {
    _ => abort("the platform has no entropy source")
  }
  span.add_event("cache.miss", at=started + 1_000_000L)
  span.set_attribute("http.response.status_code", @trace.Int(200L))
  span.set_status(@trace.Ok)

  // The same span is what makes the two log records joinable to the trace.
  let logger = @log.Logger::new(
    sink=logs,
    now=millis,
    scope="moontel-example/orders",
  ).inside(span)
  logger.info(
    "order placed",
    attributes=[("order.id", @trace.Int(42L))],
    at=started + 2_000_000L,
  )
  logger.warn("payment retried once", at=started + 3_000_000L)
  span.finish(at=started + 4_000_000L)

  // A program that already keeps metrics does not keep a second set: this reads the
  // snapshot and the bridge turns it into OTLP. The histogram is registered with its
  // unit, which the exposition appends to the name and the bridge takes back off.
  let registry = @metric.Registry::new()
  let placed = registry.counter("orders_placed", "Orders placed.")
  placed.inc(by=1.0)
  let latency = registry.histogram(
    "order_latency",
    "Order latency.",
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1],
    unit="seconds",
  )
  latency.observe(0.012)
  for metric in @p8s.bridge(registry.collect(at=0.0), at=started) {
    metrics.record(metric)
  }

  let spans = traces.flush()
  let records = logs.flush()
  let points = metrics.flush()
  report("traces", spans)
  report("logs", records)
  report("metrics", points)

  let failed = !delivered(spans) || !delivered(records) || !delivered(points)
  if failed && required {
    abort("a collector was named at \{endpoint} and did not take every signal")
  }
  if failed {
    println(
      "nothing answered at \{endpoint}; start a collector or pass its base URL",
    )
  }
}

///|
/// Whether one flush got its whole batch to the collector.
fn delivered(report : @otlp.Report) -> Bool {
  report.dropped == 0 && report.rejected == 0 && report.attempts > 0
}

///|
fn report(signal : String, outcome : @otlp.Report) -> Unit {
  println(
    "\{signal}: delivered \{outcome.delivered}, rejected \{outcome.rejected}, " +
    "dropped \{outcome.dropped}, requests \{outcome.attempts}",
  )
}

///|
/// The clock the exporters use for batching and for the retry budget, in
/// milliseconds. The runtime's is monotonic, which is what those two need; a
/// wall-clock reading would be needed only to read a `Retry-After` given as a date,
/// and this example hands its records the times it wants instead.
fn millis() -> Int64 {
  @async.now()
}

///|
fn random_bytes(width : Int32) -> Bytes {
  @moonseed.bytes(width, @system.source) catch {
    _ => abort("the platform has no entropy source")
  }
}

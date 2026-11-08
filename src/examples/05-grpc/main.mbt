// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The three signals over OTLP/gRPC: the span, the two log records and the two
/// metrics the HTTP example sends, carried by one unary call each on a channel that
/// stays open between them.
///
///     moon run src/examples/05-grpc --target native
///     moon run src/examples/05-grpc --target native -- localhost:4317
///
/// The payload is the HTTP example's on purpose: a collector that takes both runs
/// holds the same span, the same two lines and the same two metrics twice, once per
/// transport, which is how the conformance job compares the two.
///
/// The argument is `host:port`, because that is what a channel connects to; the
/// protocol puts the gRPC port at 4317. With one on the command line the program
/// requires the collector to be there and exits non-zero when it cannot be reached
/// or when a signal could not be delivered, which is what the conformance job in CI
/// runs.
#coverage.skip
async fn main {
  let arguments = @env.args()
  let address = if arguments.length() > 1 {
    arguments[1]
  } else {
    "127.0.0.1:4317"
  }
  let required = arguments.length() > 1
  let (host, port) = host_and_port(address)
  // A channel connects before anything is queued, so a collector that is not there
  // is known now rather than after a batch was built and lost. The HTTP example
  // learns the same thing at its first request; the report reads the same either
  // way.
  let transport = match channel_to(host, port) {
    Some(transport) => transport
    None => {
      if required {
        abort("a collector was named at \{address} and could not be reached")
      }
      println(
        "nothing answered at \{address}; start a collector on its gRPC port",
      )
      return
    }
  }
  // gRPC carries the binary encoding only, so the exporters are built for it. The
  // endpoint is still a URL: it names the signal, and the transport turns
  // `/v1/traces`, `/v1/logs` and `/v1/metrics` into the methods a collector serves.
  let endpoint = "http://\{address}"
  // With no collector named there is nothing to retry against, so one attempt says
  // whether something is listening without spending half a minute finding out.
  let attempts = if required { 5 } else { 1 }
  let started = 1_700_000_000_000_000_000L
  let traces = @otlp.TraceExporter::new(
    transport~,
    endpoint~,
    resource=@otlp.Resource::of_service("moontel-example").with_attribute(
      "deployment.environment.name",
      @trace.Str("test"),
    ),
    encoding=@binary.protobuf,
    now=millis,
    rand=random_bytes,
    attempts~,
  )
  let logs = @otlp.LogsExporter::new(
    transport~,
    endpoint~,
    resource=@otlp.Resource::of_service("moontel-example"),
    encoding=@binary.protobuf,
    now=millis,
    rand=random_bytes,
    attempts~,
  )
  let metrics = @otlp.MetricsExporter::new(
    transport~,
    endpoint~,
    resource=@otlp.Resource::of_service("moontel-example"),
    encoding=@binary.protobuf,
    now=millis,
    rand=random_bytes,
    attempts~,
  )

  // The span the HTTP example sends, with the same event and the same attributes.
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

  // The same span is what makes the two lines joinable to the trace on this
  // transport too: the ids travel in the record, not in the connection.
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

  // A program that already keeps metrics does not keep a second set: the snapshot
  // is read and the bridge turns it into OTLP, here as everywhere else.
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
  transport.close()
  report("traces", spans)
  report("logs", records)
  report("metrics", points)

  let failed = !delivered(spans) || !delivered(records) || !delivered(points)
  if failed && required {
    abort("a collector was named at \{address} and did not take every signal")
  }
  if failed {
    println(
      "nothing answered at \{address}; start a collector on its gRPC port",
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
/// The channel to the collector, or `None` when nothing is listening there: a
/// refused connection is the answer to "is a collector running", not a crash.
async fn channel_to(host : String, port : Int32) -> @grpc.GrpcTransport? {
  Some(@grpc.GrpcTransport::connect(host~, port~)) catch {
    _ => None
  }
}

///|
/// `host:port`, or `host` alone with the protocol's default port.
fn host_and_port(address : String) -> (String, Int32) {
  match address.rev_find(":") {
    Some(at) => (address[:at].to_owned(), port_of(address[at + 1:]))
    None => (address, 4317)
  }
}

///|
/// The port a `host:port` names, or the protocol's 4317 when the text is not a
/// number: a typo should reach the default rather than a port no one serves.
fn port_of(text : StringView) -> Int32 {
  let mut port = 0
  for digit in text {
    if digit < '0' || digit > '9' {
      return 4317
    }
    port = port * 10 + (digit.to_int() - '0'.to_int())
  }
  if port == 0 {
    4317
  } else {
    port
  }
}

///|
/// The clock the exporters use for batching and for the retry budget. The runtime's
/// is monotonic, which is what those two need; the times the signals carry are the
/// fixed ones above, in nanoseconds.
fn millis() -> Int64 {
  @async.now()
}

///|
/// Sixteen bytes from the platform's entropy source, for a span id and a trace id.
fn random_bytes(width : Int32) -> Bytes {
  @moonseed.bytes(width, @system.source) catch {
    _ => abort("the platform has no entropy source")
  }
}

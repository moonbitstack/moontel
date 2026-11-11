// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Eight instruments, three views, one exporter.
///
///     moon run src/examples/06-meter --target native -- http://localhost:4318
///     moon run src/examples/06-meter --target native -- dump
///
/// With an endpoint the program requires the collector to be there. With `dump`
/// it writes one `ExportMetricsServiceRequest` to standard output, which is the
/// payload the live-check job reads back and compares against the semantic
/// conventions. Both paths come from the same `MeterProvider::collect`.
///
/// The point of the picture is what the meter does that a plain counter does not:
/// three instruments report at collection time, one distribution adapts its buckets
/// to the measurements, and three views say what the metrics look like on the wire —
/// a name, a set of attributes, and an instrument nobody asked for.
#coverage.skip
async fn main {
  let arguments = @env.args()
  let mode = if arguments.length() > 1 {
    arguments[1]
  } else {
    "http://localhost:4318"
  }
  let started = 1_700_000_000_000_000_000L
  let resource = @otlp.Resource::of_service("moontel-example")
  // `openai` is one of the provider names the semantic conventions enumerate; a
  // name outside that list is a value no dashboard can join on.
  let attributes = @meter.gen_ai_client_attributes(
    provider="openai",
    operation="chat",
    request_model="gpt-4o",
    response_model="gpt-4o-2024-08-06",
  )
  if mode == "dump" {
    let recorder = @otlp.MetricRecorder::new()
    let provider = @meter.MeterProvider::new(
      sink=recorder,
      now=() => started,
      views=views(),
      current=() => Some(request_span),
      start=started,
    )
    record(provider, attributes, started) catch {
      _ => abort("an instrument name was refused")
    }
    println(
      @otlp.encode_metrics(provider.collect(at=started + 1_000_000L), resource~),
    )
    return
  }
  let transport = @http.HttpTransport::new()
  let exporter = @otlp.MetricsExporter::new(
    transport~,
    endpoint=mode,
    resource~,
    now=millis,
    rand=random_bytes,
  )
  let provider = @meter.MeterProvider::new(
    sink=exporter,
    now=millis,
    views=views(),
    current=() => Some(request_span),
    start=started,
  )
  record(provider, attributes, started) catch {
    _ => abort("an instrument name was refused")
  }
  // `emit` queues the metrics on the same exporter that carries spans and logs;
  // `flush` is what puts them on the wire.
  provider.emit(at=started + 1_000_000L) |> ignore
  let report = exporter.flush()
  println(
    "metrics: delivered \{report.delivered}, rejected \{report.rejected}, " +
    "dropped \{report.dropped}, requests \{report.attempts}",
  )
  if report.dropped != 0 || report.rejected != 0 || report.attempts == 0 {
    abort("a collector was named at \{mode} and did not take every metric")
  }
}

///|
/// The span the program is inside while it records. A real service hands the span it
/// already has; here it is fixed, so the exemplar a backend shows names the same
/// trace on every run.
let request_span : @trace.TraceContext = @trace.TraceContext::new(
  trace_id=b"\x4b\xf9\x2f\x35\x77\xb3\x4d\xa6\xa3\xce\x92\x9d\x0e\x0e\x47\x36",
  span_id=b"\x00\xf0\x67\xaa\x0b\xa9\x02\xb7",
  flags=@trace.sampled_flag,
)

///|
/// What the three views say about the metrics this program registers.
///
/// A view is the only place a decision about the wire belongs: the call sites keep
/// writing the measurements they can measure, and the program decides here that a
/// token count does not need the response model, that a queue depth reads better as a
/// length, and that a debug tick is not worth sending at all.
fn views() -> Array[@meter.View] {
  [
    @meter.View::new(instrument="gen_ai.client.token.usage", attribute_keys=[
      @semconv.gen_ai_provider_name, @semconv.gen_ai_operation_name, @semconv.gen_ai_request_model,
    ]),
    @meter.View::new(
      instrument="gen_ai.client.queue.depth",
      name="gen_ai.client.queue.length",
      attribute_keys=[
        @semconv.gen_ai_provider_name, @semconv.gen_ai_operation_name,
      ],
    ),
    @meter.View::new(
      instrument="moontel.example.debug.tick",
      aggregation=@meter.Drop,
    ),
  ]
}

///|
/// The instruments a service would register once and write to on every request.
/// Every name and every attribute key keeps its dots, because OTLP and the semantic
/// conventions both spell them that way.
fn record(
  provider : @meter.MeterProvider,
  attributes : @meter.Attributes,
  started : Int64,
) -> Unit raise @meter.Refused {
  let meter = provider.meter(name="moontel-example/orders")
  let tokens = meter.counter(
    "gen_ai.client.token.usage",
    description="Tokens used by the client.",
    unit="{token}",
  )
  tokens.add(128.0, attributes~, at=started, context=request_span)
  let duration = meter.histogram(
    @semconv.gen_ai_client_operation_duration,
    description="GenAI operation duration.",
    unit="s",
  )
  duration.record(6.0, attributes~, at=started, context=request_span)
  let active = meter.up_down_counter(
    "gen_ai.client.active.requests",
    description="Requests in flight.",
    unit="{request}",
  )
  active.add(3.0, attributes~, at=started)
  active.add(-1.0, attributes~, at=started)
  // An observed gauge: the callback runs at each collection, so the number is what
  // the queue holds now rather than what it held when a request last ran.
  let _ = meter.observable_gauge(
    "gen_ai.client.queue.depth",
    description="Requests waiting.",
    unit="{request}",
    observe=fn(observer) { observer.observe(7.0, attributes~, at=started) },
  )
  let _ = meter.observable_counter(
    "gen_ai.client.tokens.reported",
    description="Tokens the client has used, as the provider counts them.",
    unit="{token}",
    observe=fn(observer) { observer.observe(512.0, attributes~, at=started) },
  )
  let _ = meter.observable_up_down_counter(
    "gen_ai.client.workers.reported",
    description="Workers the client keeps for the model.",
    unit="{worker}",
    observe=fn(observer) { observer.observe(4.0, attributes~, at=started) },
  )
  // A distribution whose buckets follow the measurements: the five values below span
  // four orders of magnitude, which explicit boundaries at the wrong scale would
  // throw into one bucket.
  let latency = meter.exponential_histogram(
    "moontel.example.latency",
    description="Time a request took, at any scale.",
    unit="s",
  )
  for value in [0.004, 0.011, 0.052, 0.19, 1.7] {
    latency.record(value, attributes~, at=started, context=request_span)
  }
  // Registered, written, and dropped by a view: the point of a view is that the call
  // site does not have to know.
  let tick = meter.counter(
    "moontel.example.debug.tick",
    description="A tick nobody needs on a dashboard.",
  )
  tick.inc(at=started)
}

///|
fn millis() -> Int64 {
  @async.now()
}

///|
fn random_bytes(width : Int32) -> Bytes {
  @moonseed.bytes(width, @system.source) catch {
    _ => abort("the platform has no entropy source")
  }
}

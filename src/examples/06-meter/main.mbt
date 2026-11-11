// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Four instruments, one attribute group, one exporter.
///
///     moon run src/examples/06-meter --target native -- http://localhost:4318
///     moon run src/examples/06-meter --target native -- dump
///
/// With an endpoint the program requires the collector to be there. With `dump`
/// it writes one `ExportMetricsServiceRequest` to standard output, which is the
/// payload the live-check job reads back and compares against the semantic
/// conventions. Both paths come from the same `MeterProvider::collect`.
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
/// The four instruments a service would register once and write to on every
/// request. Every name and every attribute key keeps its dots, because OTLP and
/// the semantic conventions both spell them that way.
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
  tokens.add(128.0, attributes~, at=started)
  let duration = meter.histogram(
    @semconv.gen_ai_client_operation_duration,
    description="GenAI operation duration.",
    unit="s",
  )
  duration.record(6.0, attributes~, at=started)
  let active = meter.up_down_counter(
    "gen_ai.client.active.requests",
    description="Requests in flight.",
    unit="{request}",
  )
  active.add(3.0, attributes~, at=started)
  active.add(-1.0, attributes~, at=started)
  let depth = meter.gauge(
    "gen_ai.client.queue.depth",
    description="Requests waiting.",
    unit="{request}",
  )
  depth.set(7.0, attributes~, at=started)
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

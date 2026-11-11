---
name: moontel
description: "OpenTelemetry for MoonBit: spans, samplers, the W3C headers that carry a trace between services, log records written beside a span, a meter with counters, up-down counters, histograms and gauges, and export of all three signals to a collector over OTLP. Use it to add tracing or metrics to a MoonBit service, to join a trace that arrives with a request, or to send spans, logs and metrics somewhere that reads them."
---

# moontel

```sh
moon add moonbitstack/moontel
```

| Package | What it is for |
|:--|:--|
| `moonbitstack/moontel/trace` | spans, samplers, the `Sink` a finished span goes to |
| `moonbitstack/moontel/propagate` | `traceparent`, `tracestate` and `baggage` |
| `moonbitstack/moontel/log` | records, a logger, sinks |
| `moonbitstack/moontel/meter` | counters, up-down counters, histograms, gauges |
| `moonbitstack/moontel/otlp` | the export: queue, batch, retry, the JSON body |
| `moonbitstack/moontel/otlp/http` | the transport over an HTTP connection |
| `moonbitstack/moontel/otlp/binary` | the binary body, when the collector wants protobuf |
| `moonbitstack/moontel/otlp/grpc` | the same body over one unary call |
| `moonbitstack/moontel/semconv` | the GenAI semantic conventions as constants |

`moonbitstack/moontel` itself is a facade that re-exports the first five.

## Trace a unit of work

The library reads no clock and opens no socket: it is handed the time and the ids,
and finished spans leave through a sink.

```moonbit
fn random_bytes(n : Int32) -> Bytes {
  let out = Bytes::make(n, b'\x01')
  out
}

fn clamps(rand : (Int32) -> Bytes, at : Int64) -> @trace.Span raise {
  let tracer = @trace.Tracer::new(
    rand~,
    sink=@trace.Recorder::new(),
    sampler=@trace.parent_based(root=@trace.always),
  )
  let span = tracer.start("GET /orders/{id}", kind=@trace.Server, at~)
  span.set_attribute("http.request.method", @trace.Str("GET"))
  span.set_status(@trace.Ok)
  span.finish(at=at + 1_000_000L)
  span
}
```

`@trace.Recorder` keeps spans in memory for a test or a debugging run. Everywhere
else, hand the tracer the exporter further down this page, or a `Sink` of your own.

`start` can refuse: a random source that returns the wrong number of octets, or all
zeros, gives `@trace.Refused` rather than an id that matches nothing.

## Join a trace that arrives with a request

```moonbit
fn context_of(headers : Array[(String, String)]) -> @trace.TraceContext? {
  @propagate.extract(headers).context
}

fn headers_of(span : @trace.Span) -> Array[(String, String)] {
  @propagate.inject([], { context: Some(span.context()), baggage: @propagate.Baggage::new() })
}
```

Pass what `extract` returns as `parent?` to the next `start`, and put what `inject`
returns on the outgoing request. Both headers are W3C: `traceparent` and `tracestate`,
plus `baggage` when the context carries any. A header that does not parse leaves its
own field empty and leaves the rest intact.

## Send the three signals to a collector

The HTTP transport is built on a connection pool, so it compiles for native and
wasm and not for the JavaScript backends:

```moonbit native
fn exporter(endpoint : String, now : () -> Int64, rand : (Int32) -> Bytes) -> @otlp.TraceExporter {
  let transport = @http.HttpTransport::new()
  @otlp.TraceExporter::new(
    transport~,
    endpoint~,
    resource=@otlp.Resource::of_service("orders"),
    now~,
    rand~,
  )
}
```

The exporter is a `@trace.Sink` and a queue: accepting a span never waits for the
collector. `flush` sends everything now, `run` keeps sending on its own. `LogsExporter`
and `MetricsExporter` have the same shape.

The default body is JSON. For the binary encoding, hand it the other one:

```moonbit native
fn binary_exporter(endpoint : String, now : () -> Int64, rand : (Int32) -> Bytes) -> @otlp.TraceExporter {
  let transport = @http.HttpTransport::new()
  @otlp.TraceExporter::new(
    transport~,
    endpoint~,
    encoding=@binary.protobuf,
    now~,
    rand~,
  )
}
```

`otlp/grpc` is a transport of the same exporters — spans, log records and metrics all
travel over it — and takes the binary encoding only:

```moonbit native
async fn grpc_exporter(now : () -> Int64, rand : (Int32) -> Bytes) -> @otlp.TraceExporter {
  let channel = @grpc.GrpcTransport::connect(host="localhost")
  @otlp.TraceExporter::new(
    transport=channel,
    endpoint="http://localhost:4317",
    encoding=@binary.protobuf,
    now~,
    rand~,
  )
}
```

## Count what a service does

The meter keeps four instruments. Register a name once, keep the handle, and write
to it on the request path.

```moonbit
fn instrument(provider : @meter.MeterProvider, seconds : Double) -> Unit raise {
  let attributes = @meter.gen_ai_client_attributes(
    provider="openai",
    operation="chat",
    request_model="gpt-4o",
  )
  let meter = provider.meter(name="checkout")
  let duration = meter.histogram(
    "gen_ai.client.operation.duration",
    description="GenAI operation duration.",
    unit="s",
  )
  duration.record(seconds, attributes~, at=0L)
  let tokens = meter.counter("gen_ai.client.token.usage", unit="{token}")
  tokens.add(128.0, attributes~, at=0L)
  let in_flight = meter.up_down_counter(
    "gen_ai.client.active.requests",
    unit="{request}",
  )
  in_flight.add(1.0, attributes~, at=0L)
  in_flight.add(-1.0, attributes~, at=0L)
  let depth = meter.gauge("gen_ai.client.queue.depth", unit="{request}")
  depth.set(0.0, attributes~, at=0L)
}

fn meter_for(exporter : @otlp.MetricsExporter, now : () -> Int64) -> @meter.MeterProvider {
  @meter.MeterProvider::new(sink=exporter, now~, start=now())
}

fn write_metrics(provider : @meter.MeterProvider) -> Array[@otlp.Metric] {
  provider.emit(at=1_000_000L)
}
```

`@otlp.MetricsExporter` is a `@otlp.MetricSink`, so the meter writes through the same
exporter, resource and transport as spans and logs. `collect` returns the points
without writing them; `emit` writes them and, for a delta reader, clears the
accumulations afterwards.

A histogram without `bounds` uses the fifteen boundaries the metrics SDK specifies,
`[0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]`. Pass a
sampled `@trace.TraceContext` as `context?` to keep an exemplar beside the series.

## Rules that catch people out

- A tracer is handed `rand~` and times; it never reads either itself. The same tracer
  code then serves a server, a replay of last night's batch, and a test.
- Use `parent_based` in a service. `always` in every hop makes a trace's shape depend
  on which hop rolled the dice.
- `start` raises `@trace.Refused`, so a function that starts a span either raises or
  handles it.
- The exporter batches: a program that ends without `flush` loses what is queued.
  `tick` sends what is due, `run` loops on it.
- `otlp/grpc` is native only — it needs a socket. `otlp/binary` and `otlp` build for
  every backend.
- A span past the library's limits drops the write and counts it in
  `SpanData::dropped`; it does not fail the call.
- `semconv` is constants only. A key spelled by hand is a key no dashboard matches.
- A counter's `add` ignores a negative or non-finite amount; an up-down counter takes
  either sign; a gauge's `set` replaces the value instead of adding to it.
- One name is one instrument, case-insensitively. Registering the same name as a
  second kind raises `@meter.Refused`, rather than silently changing what the series
  means.
- Attribute keys keep their dots. Sorting and deduplication happen inside
  `@meter.Attributes`; rewriting a key into underscores breaks the match.
- The meter reads no clock: `MeterProvider::new` takes `now~`, and `collect` and
  `emit` take `at~`. A histogram past its cardinality limit drops the new series and
  counts it in `MeterProvider::dropped`.

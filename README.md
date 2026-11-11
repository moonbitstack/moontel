<h1 align="center">moontel</h1>

<p align="center"><em>OpenTelemetry tracing for MoonBit.</em></p>

<p align="center">
  <a href="https://moonbitstack.github.io/moontel/"><b>Home</b></a> ·
  <a href="https://moonbitstack.github.io/moontel/guide.html"><b>Guide</b></a> ·
  <a href="https://moonbitstack.github.io/moontel/api.html"><b>API</b></a> ·
  <a href="https://mooncakes.io/docs/moonbitstack/moontel"><b>mooncakes</b></a>
</p>

---

OpenTelemetry for MoonBit: spans, the samplers that decide which of them to keep, the
headers that carry a trace from one service to the next, log records written beside a
span, the meter that counts what a service does — written as it runs or reported when
the metrics are collected — and the export of all three signals to a collector.

A request that touches five services is one trace with a tree of spans, and every
service has to agree on the same names, the same ids and the same wire format for
that to be readable. This library is that agreement: it builds the spans, decides
what to keep, and reads and writes the headers the agreement is written in —
`traceparent` and `tracestate` from W3C Trace Context, and `baggage` from W3C
Baggage.

The [documentation site](https://moonbitstack.github.io/moontel/) has a guide, the
complete reference, a showcase you can play with, and six runnable examples.

```moonbit
fn traced_request(rand : (Int32) -> Bytes, at : Int64) -> @trace.Span raise {
  let tracer = @trace.Tracer::new(
    rand~,
    sink=@trace.Recorder::new(),
    sampler=@trace.parent_based(root=@trace.always),
  )
  let span = tracer.start("GET /orders/{id}", kind=@trace.Server, at~)
  span.set_attribute("http.response.status_code", @trace.Int(200L))
  span.finish(at=at + 1_000_000L)
  span
}
```

Nothing here reads a clock, opens a socket or parses an HTTP request. Ids come from a
function you pass, times from the caller, and finished spans leave through a trait you
implement. That is what makes the same code serve a server, a batch job replaying last
night's events, and a replay that needs the timeline to be exact.

## Install

```bash
moon add moonbitstack/moontel
```

## Annotations

Trace a function by saying so on it. The function stays as it is, and a generator adds one beside it:

<!-- nocheck -->
```moonbit
#tel.span("orders.place", kind=server, attr="item")
fn place(item : String) -> Int raise Sold {
  ...
}
```

`place_traced` runs it inside a span, and takes what the span needs:

<!-- nocheck -->
```moonbit
let receipt = place_traced(tracer, "tea", now=clock)
let nested = place_traced(tracer, "tea", now=clock, parent=span.context())
```

The name defaults to the function's. `kind` is `internal`, `server`, `client`, `producer` or
`consumer`. Each `attr` records a parameter of text, a number or a boolean. What the function raises
is recorded on the span with an error status and raised on, and the span finishes whichever way the
call ends, a cancelled one included. Starting a span can be refused, so the wrapper raises even when
the function does not.

The generator wires in as a dev_build rule, in `moon.mod`:

<!-- nocheck -->
```
rule(name: "span", command: "moonx moonbitstack/moontel/cmd/span -C \"$mod_dir\" \"$input\" -o \"$output\"")
```

and in the `moon.pkg` of the package, which imports `moonbitstack/moontel/trace`:

<!-- nocheck -->
```
dev_build(rule: "span", input: "orders.mbt", output: "orders.g.mbt")
formatter(ignore: [ "orders.g.mbt" ])
```

`moon run src/examples/03-annotated` shows it, and the generated file is committed: what an
annotation means should be readable, not only runnable. `-o <file> --check` with the same arguments
answers whether the committed file is the one the generator would write — which is what CI runs, so
the two cannot drift. The rest of this page builds spans by hand, which is what the generated code
does.

## The seams

A tracer needs two things it cannot invent for itself.

**Randomness** is a `(Int32) -> Bytes`: ask for sixteen octets and get the trace id,
eight and get a span id. A broken source is refused rather than papered over — an id
of all zeros is not an id, and a generator that returns three octets when asked for
sixteen is a bug worth seeing. A tracer that hands back `Refused::Ids` or
`Refused::Zero` from `start` was given a generator that is not one.

**A sink** is where finished spans go:

```moonbit
struct Printer {}

impl @trace.Sink for Printer with fn accept(self, span) {
  ignore(self)
  println("\{span.name} took \{span.duration()} ns")
}

fn traced_with_printer(rand : (Int32) -> Bytes, at : Int64) -> Unit raise {
  let tracer = @trace.Tracer::new(rand~, sink=Printer::{}, sampler=@trace.always)
  let span = tracer.start("GET /orders/{id}", at~)
  span.finish(at=at + 1L)
}
```

`Recorder` keeps spans in memory, which is what examples and debugging want. `Discard`
throws them away, which is what a program that only wants trace ids for its logs
wants. A collector, a file or a queue a background task drains is a `Sink` of your own,
and the transport stays yours; the library's own exporter is one such sink, and the
request it makes is handed to a `Transport` for the same reason.

A sink is handed every span that was recorded, including the ones the sampler kept out
of the trace. `SpanData::sampled` is the bit that separates "keep for counting" from
"send to the backend".

## Sampling

Four samplers, the ones the OpenTelemetry specification names:

| Sampler | What it decides |
|:--|:--|
| `always` | Everything is sampled. |
| `never` | Nothing is sampled. |
| `ratio(ratio=0.1)` | A tenth of traces, chosen by the trace id. |
| `parent_based(root=...)` | The parent's decision, or `root` when there is no parent. The other four rows, a remote or local parent sampled or not, are arguments too. |

`ratio` reads the low 64 bits of the trace id, so the same trace gets the same answer
on every hop and in every service, and a service running at a higher rate keeps
everything a lower-rate service kept.

`parent_based` is the one to give a service. The hop that started the trace chose for
the whole trace; every later hop obeys instead of rolling its own dice, which is what
keeps a five-service request in one piece.

A sampler of your own is one trait implementation:

```moonbit
struct Everything {}

impl @trace.Sampler for Everything with fn should_sample(_, _) {
  @trace.RecordAndSample
}

impl @trace.Sampler for Everything with fn description(_) {
  "Everything"
}
```

## Carrying a trace between services

A request arrives with headers, and the hop reads them:

```moonbit
fn trace_on_request(headers : Array[(String, String)]) -> @trace.TraceContext? {
  @propagate.extract(headers).context
}

fn inbound_headers() -> Array[(String, String)] {
  [
    ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
    ("tracestate", "vendor=abc"),
    ("baggage", "userId=alice"),
  ]
}
```

The result is the trace to join or `None`, and `@propagate.extract(headers).baggage`
is what rode along. A header that does not parse leaves its field empty and the rest
intact: a mangled `tracestate` costs the hop its vendor state, not its trace.

Sending a request on is the same value in reverse:

```moonbit
fn forward(
  headers : Array[(String, String)],
  span : @trace.Span,
  baggage : @propagate.Baggage,
) -> Array[(String, String)] {
  @propagate.inject(headers, { context: Some(span.context()), baggage })
}
```

The propagation headers already in the list are replaced, everything else is left
alone, and the context written is this hop's span, so the next service hangs its spans
under this one.

`@propagate.parse` and `@propagate.parse_traceparent` are there for a caller that wants
the fields and the refusal; `Baggage::parse` and `Baggage::to_header` are the same pair
for `baggage`.

## ASGI

The `asgi` package is one middleware in the shape ASGI frameworks stack:

```moonbit
fn layer(tracer : @trace.Tracer, now : () -> Int64) -> @asgi.Tracing {
  @asgi.Tracing::new(tracer~, now~)
}
```

`layer(tracer, now).wrap(application)` is the traced application, and `stack` from the
framework's own middleware package takes it beside the rest.

For every HTTP request it reads the context off the scope, opens a span of kind
`Server` under it, puts the request's method, path, scheme, server, client and protocol
on the span, records the response status, marks a 5xx as an error, and writes the
context back on the response headers. The span ends when the application returns, and
an application that raises leaves an `exception` event behind before the error goes on
to the server.

`now` is the clock, in nanoseconds: the middleware needs two readings per request and
takes them from you. `ignore` skips paths that would only be noise, `name` changes how
a request is named when you know your routes, and `baggage=false` stops the vendor data
at this hop.

A WebSocket or a lifespan scope is passed straight through: a `Server` span for either
needs a different set of attributes, and a wrong span is worse than a missing one.

## Sending the signals

A sink decides where spans go, and one that speaks OTLP over HTTP is part of the
library. It queues what the tracer finishes and posts it, so accepting a span never
waits for a collector:

```moonbit native
fn traced(now : () -> Int64, rand : (Int32) -> Bytes) -> @trace.Tracer {
  let transport = @http.HttpTransport::new()
  let exporter = @otlp.TraceExporter::new(
    transport~,
    endpoint="http://localhost:4318",
    resource=@otlp.Resource::of_service("orders"),
    now~,
    rand~,
  )
  @trace.Tracer::new(rand~, sink=exporter, sampler=@trace.parent_based(root=@trace.always))
}
```

The same shape exists for log records and for metrics. What is inside is the SDK's
batch processor: a queue of 2048, at most 512 records per request, a request every five
seconds, thirty seconds for one to finish. A refusal is retried when the protocol says
it may be — `429`, `502`, `503`, `504` — after the wait a `Retry-After` header asks for,
or an exponential backoff of five seconds times one and a half, capped at thirty and
jittered by a fifth. Any other refusal is final. `flush` sends everything now and
returns what happened to it.

Two bounds come from the protocol as well: this side sends no body over 64 MiB and reads
no reply over 4 MiB. A body past the first is never sent — the records are counted as
dropped — and a reply past the second is never parsed and never retried. `limits` moves
either number.

`otlp` writes the request; `otlp/http` carries it. A program that only needs to encode a
payload, or a test that answers from a script, implements `Transport` and pulls in no
socket.

A body may be compressed: `HttpTransport::new(compression=@http.Compression::Gzip)`
gzipping every request and setting `Content-Encoding: gzip` with it. The body and the
header that describes it are decided in one place, so one cannot arrive without the
other.

A body has two encodings, and an exporter is handed the one it should write. The
default is the JSON mapping; `encoding=@binary.protobuf` sends the binary one under
`Content-Type: application/x-protobuf` — the same fields with no field names, about a
third of the bytes — which is the encoding the protocol says every exporter must be
able to send:

```moonbit native
fn traced_binary(now : () -> Int64, rand : (Int32) -> Bytes) -> @trace.Tracer {
  let transport = @http.HttpTransport::new()
  let exporter = @otlp.TraceExporter::new(
    transport~,
    endpoint="http://localhost:4318",
    encoding=@binary.protobuf,
    now~,
    rand~,
  )
  @trace.Tracer::new(rand~, sink=exporter, sampler=@trace.parent_based(root=@trace.always))
}
```

The encoder, the `Content-Type` it is sent under and the way a reply's count of refused
records is read all come from that one value, so a request cannot leave announcing one
encoding and carrying the other. `otlp` ships the JSON one and nothing else: a program
that sends JSON compiles neither a schema runtime nor a protobuf message.

That is what `otlp/binary` is — the protocol's messages, generated from its own schema
(`scripts/otlp-schema` is the pinned copy, `src/cmd/gen-otlp-proto` the generator), and
the encoder that fills them in. Every field number in a body comes from the `.proto`
file rather than from a writer that remembered it.

gRPC is a transport of its own, `otlp/grpc`, carrying that binary encoding over one
long-lived channel and one unary call per request:

```moonbit native
async fn over_grpc(now : () -> Int64, rand : (Int32) -> Bytes) -> @otlp.TraceExporter {
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

gRPC has no JSON encoding, so an exporter over it is always built with
`@binary.protobuf`; the queue, the batch, the retry rules and the size bounds are the
same code, and a gRPC status is translated into the HTTP status those rules are
written against. The transport is the only thing that changes: the span exporter, the
log exporter and the metric exporter all take it, so a collector receives the same
three signals over either transport.

## Logs

A record says when it happened, how urgent it is, what it says and which span it was
written in. A logger is what the lines from one part of a program share:

```moonbit
fn failing(logs : &@log.Sink, span : @trace.Span, now : () -> Int64) -> Unit {
  let logger = @log.Logger::new(sink=logs, now~, scope="orders/payments").inside(span)
  logger.info("order placed", attributes=[("order.id", @trace.Int(42L))])
  logger.warn("the card was retried once")
}
```

A record can carry the failure that caused it: `error=` adds `exception.message`, and
the line's own attributes win over it when they name that key.

`inside(span)` stamps every record with that span's trace and span ids, which is what
lets a backend show the line beside the work it belongs to. A logger can drop
everything below a floor, or everything written inside a trace nobody sampled, and can
ask first with `enabled`. A record that names itself becomes a span event through
`SpanEvents`, and a `Fanout` sends the same record to several sinks at once.

`log/moonlog_bridge` does the same for lines a program already writes through a
structured logger: the level, the fields and the caller's file and line become a record.

## Metrics

The meter keeps three instrument families. Four are written as the program runs: a
counter, an up-down counter, a histogram and a gauge. Three report themselves when the
metrics are collected: an observable counter, an observable up-down counter and an
observable gauge. The eighth is a distribution whose buckets follow the measurements.
Register each name once, write to the handle on the request path or hand in a callback,
and give the exporter the same object spans and logs already leave through.

```moonbit
fn record_latency(
  provider : @meter.MeterProvider,
  seconds : Double,
  attributes : @meter.Attributes,
) -> Unit raise {
  let meter = provider.meter(name="checkout")
  let duration = meter.histogram(
    "gen_ai.client.operation.duration",
    description="GenAI operation duration.",
    unit="s",
  )
  duration.record(seconds, attributes~, at=0L)
}

fn collect(provider : @meter.MeterProvider) -> Array[@otlp.Metric] {
  provider.collect(at=1_000_000L)
}
```

`Counter::add` refuses a negative amount, `UpDownCounter::add` takes either sign,
`Gauge::set` keeps the last value, and `Histogram::record` fills the bucket whose
upper bound contains the measurement. Names and attribute keys keep their dots:
`gen_ai.client.operation.duration` is exported as written, because that is the
spelling a backend matches on.

### Reported at collection

A queue depth is not something to add up; it is something to look at when the reader
asks. An observable instrument takes a callback instead of a value, and the callback
runs once per collection:

```moonbit
fn queue_depth(provider : @meter.MeterProvider) -> Unit raise {
  let meter = provider.meter(name="checkout")
  let queue = meter.observable_gauge(
    "checkout.queue.depth",
    description="Requests waiting.",
    unit="{request}",
    observe=fn(observer) { observer.observe(7.0) },
  )
  ignore(queue)
}
```

What the callback states is a total, not an increment: a cumulative reader sees
`7`, and a delta reader sees the change since the last export — the first export
reports `7`, the next one reports `7` less than it reports now, and nothing if the
queue did not move. That is the difference between an observed value and a written
one, and it is why an observable counter can be exported at all to a scraper that
wants per-interval numbers.

### Buckets that follow the measurements

A histogram over fixed boundaries answers the questions its boundaries were chosen
for. An exponential histogram answers at every scale: bucket `i` covers
`(2^(i/2^scale), 2^((i+1)/2^scale)]`, so a millisecond and a minute are both resolved
finely, and when the measurements spread wider than the bucket budget the buckets merge
in pairs and the scale drops by one.

```moonbit
fn exponential_latency(provider : @meter.MeterProvider) -> Unit raise {
  let meter = provider.meter(name="checkout")
  let latency = meter.exponential_histogram(
    "checkout.latency",
    description="Time a request took.",
    unit="s",
  )
  latency.record(0.004, at=0L)
  latency.record(0.052, at=0L)
  latency.record(1.7, at=0L)
}
```

`scale` starts at 20, the finest the SDK defines, and `max_buckets` is 160, its
default; the point carries the scale it settled on, so a reader never has to guess
what a bucket index means. Measurements of exactly zero are counted separately, and
the negative side is mirrored rather than folded into the positive one.

### Views

A view decides what a metric looks like on the wire without touching the call sites:
a new name, a new description, which attributes survive, a different aggregation, or
that the instrument is not wanted at all.

```moonbit
fn viewed_provider() -> @meter.MeterProvider {
  @meter.MeterProvider::new(
    sink=@otlp.MetricRecorder::new(),
    now=() => 0L,
    views=[
      @meter.View::new(
        instrument="checkout.token.usage",
        name="checkout.tokens",
        attribute_keys=["gen_ai.provider.name"],
      ),
      @meter.View::new(instrument="checkout.debug.tick", aggregation=@meter.Drop),
    ],
  )
}
```

`instrument` is a name or `*`; `kind` narrows a wildcard to one type of instrument.
`attribute_keys` is an allowlist, and dropping a key that told two requests apart is
how two series become one with the sum of both. One instrument seen through two views
is two metrics, and a `Drop` view leaves the instrument registered and nothing on the
wire — which is what makes a metric cheap to retire. A view that asks for a
distribution of an observed instrument keeps the instrument's own aggregation: a
callback states values, and a histogram of values that are already aggregates measures
nothing.

### Exemplars

An exemplar is a sample of what a number was made of: one measurement, the trace it
was taken in, and the attributes of its series. A reader that sees a bucket double can
follow the exemplar to the request that filled it.

```moonbit
fn with_current_span(span : @trace.TraceContext) -> @meter.MeterProvider {
  @meter.MeterProvider::new(
    sink=@otlp.MetricRecorder::new(),
    now=() => 0L,
    current=() => Some(span),
  )
}
```

`current` is the span the program is inside; a measurement that names a `context` of
its own wins over it. The filter is `@meter.TraceBased` by default — only a sampled,
valid trace becomes an exemplar, because an exemplar from a trace nobody kept names a
span no backend holds. `AlwaysOn` keeps every measurement, `AlwaysOff` keeps none, and
`MeterLimits::exemplars` says how many a series keeps.

`MeterProvider::new` takes the sink that finished metrics go to and the clock the
caller trusts. A `@otlp.MetricsExporter` is a sink, so the resource, the transport,
the batching and the retry rules are the ones that already carry the other two
signals. The provider also takes the temporality a reader wants, cumulative by
default and delta for a scraper, and the limits that keep one instrument bounded.

The default histogram boundaries are the fifteen values the metrics SDK specifies,
`[0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]`; pass
`bounds` to a histogram to use others. Each recorded point carries its own `sum`,
`count`, `min` and `max`, and a sampled trace context becomes an exemplar, which is
how a reader jumps from a slow bucket to the request that filled it.

An attribute set is identified by its keys, not by the order they were written in.
`Attributes::new` sorts and deduplicates, and `gen_ai_client_attributes` fills the
GenAI group from the `semconv` constants:

```moonbit
fn chat_attributes() -> @meter.Attributes {
  @meter.gen_ai_client_attributes(
    provider="openai",
    operation="chat",
    request_model="gpt-5",
  )
}
```

A program that already counts with a Prometheus-style registry does not need a
second set of numbers. The bridge turns the snapshot it takes into OTLP metrics:

```moonbit
fn export(
  metrics : @otlp.MetricsExporter,
  now : () -> Int64,
  elapsed : Double,
) -> Unit raise {
  let registry = @metric.Registry::new()
  let latency = registry.histogram("order_latency", "Latency.", unit="seconds")
  latency.observe(elapsed)
  for metric in @p8s.bridge(registry.collect(at=0.0), at=now()) {
    metrics.record(metric)
  }
}
```

A counter becomes a cumulative monotonic sum, a gauge stays a gauge, a histogram
becomes one with explicit bounds, and a summary stays a summary. A gauge histogram has
no OTLP instrument and is dropped; `bridge_with_report` returns the families it dropped
alongside the metrics, so a program can count them.

The name a program registered is the name OTLP sees. A registry appends the unit to the
name it writes — `order_latency` with unit `seconds` is exposed as
`order_latency_seconds` — and the suffix comes back off here, because it is the
exposition's doing rather than a rename. The unit travels in its own field, translated
to the code the compatibility specification lists, `s` or `By`. A name that does not end
in its own unit, and a `_total`, are left as they are.

## The GenAI names

`semconv` is constants and nothing else: the attribute keys, metric names, span types
and event names of the OpenTelemetry GenAI semantic conventions, generated from the
upstream registry and pinned to a commit. A key spelled by hand is a key no dashboard
matches, and this package is where the spelling lives.

## The interface

Twelve packages, five of them subpackages, plus a facade that re-exports five of them.
Import the package that owns the type you construct — an enum constructor is reached
through the package that defines it, not through the facade.

### `trace` — spans, samplers, the sink seam

| Item | Signature |
|:--|:--|
| `Tracer::new` | `(rand~ : (Int32) -> Bytes, sink~ : &Sink, sampler~ : &Sampler, limits? : Limits) -> Tracer` |
| `Tracer::start` | `(name, parent? : TraceContext, kind? : SpanKind, at~ : Int64, attributes?, links?) -> Span raise Refused` |
| `Span::finish` | `(at~ : Int64) -> Unit` |
| `Span::set_attribute` | `(key : String, value : Value) -> Unit` |
| `Span::set_attributes` | `(Array[(String, Value)]) -> Unit` |
| `Span::add_event` | `(name, attributes?, at~ : Int64) -> Unit` |
| `Span::record_exception` | `(message~, at~, type_?, stacktrace?, attributes?) -> Unit` |
| `Span::set_status` | `(Status) -> Unit` |
| `Span::set_name` | `(String) -> Unit` |
| `Span::add_link` | `(Link) -> Unit` |
| `Span::context` | `() -> TraceContext` |
| `Span::is_recording`, `is_ended` | `() -> Bool` |
| `SpanData` | `context, parent, name, kind, start, end, attributes, events, links, status, dropped` |
| `SpanData::sampled`, `duration` | `() -> Bool`, `() -> Int64` |
| `TraceContext` | `trace_id : Bytes, span_id : Bytes, flags : Byte, state : TraceState` |
| `TraceContext::to_traceparent` | `() -> String` |
| `TraceState::parse` | `(StringView) -> TraceState raise Refused` |
| `TraceState::to_header` | `() -> String` |
| `TraceState::get`, `insert`, `delete` | read a member, add one closest to this hop, drop one |
| `Sampler` | `should_sample(SampleRequest) -> Decision`, `description() -> String` |
| `Sink` | `accept(SpanData) -> Unit` |
| `Limits` | `attributes, events, links, attributes_per_event, attribute_value_length` |
| `Status` | `Unset`, `Ok`, `Error(String)` |
| `SpanKind` | `Internal`, `Server`, `Client`, `Producer`, `Consumer` |
| `Value` | `Bool`, `Int`, `Double`, `Str`, and the four typed arrays |

### `propagate` — the W3C headers

| Item | Signature |
|:--|:--|
| `extract` | `(Array[(String, String)]) -> Extracted` |
| `inject` | `(Array[(String, String)], Extracted) -> Array[(String, String)]` |
| `parse` | `(traceparent : StringView, tracestate? : StringView) -> TraceContext raise Refused` |
| `parse_traceparent` | `(StringView) -> TraceContext raise Refused` |
| `parse_tracestate` | `(StringView) -> TraceState raise Refused` |
| `Baggage` | `members : Array[Member]`, with `parse`, `to_header`, `get`, `len`, `add` |

### `asgi` — the middleware

| Item | Signature |
|:--|:--|
| `Tracing::new` | `(tracer~, now~ : () -> Int64, name?, baggage? : Bool, ignore? : Array[String]) -> Tracing` |
| `Tracing::wrap` | `(AsgiApp) -> AsgiApp`, and `Layer` for stacking with other middleware |

### `log` — records, the logger, the sinks

| Item | Signature |
|:--|:--|
| `Logger::new` | `(sink~ : &Sink, now~ : () -> Int64, scope?, attributes?, floor? : Severity, trace_based? : Bool, limits? : Limits) -> Logger` |
| `Logger::log` | `(severity : Severity, body : Value, attributes?, at? : Int64, observed? : Int64, event_name? : String, error? : Error) -> Unit` |
| `Logger::write`, `trace`, `debug`, `info`, `warn`, `error`, `fatal` | a text body at one severity |
| `Logger::inside` | `(Span) -> Logger` — every record it writes names that span |
| `Logger::with_context` | `(TraceContext) -> Logger` |
| `Logger::under`, `with_attribute`, `enabled` | name a nested scope, carry a field, ask before building a body |
| `LogRecord` | `time, observed, severity, severity_text, body, attributes, trace_id, span_id, flags, event_name, scope, dropped` |
| `LogRecord::with_context`, `with_attribute`, `with_event_name`, `timestamp`, `context` | build one, and read what it names |
| `Severity` | `Trace`, `Debug`, `Info`, `Warn`, `Error`, `Fatal`, numbered 1, 5, 9, 13, 17, 21 |
| `Sink` | `accept(LogRecord) -> Unit` |
| `Recorder`, `Discard`, `Fanout`, `SpanEvents` | in memory, thrown away, several sinks, and a bridge onto the span |

### `meter` — the instruments, the views and the exemplars

| Item | Signature |
|:--|:--|
| `MeterProvider::new` | `(sink~ : &MetricSink, now~ : () -> Int64, temporality? : Temporality, limits? : MeterLimits, exemplar? : ExemplarFilter, current? : () -> TraceContext?, views? : Array[View], start? : Int64) -> MeterProvider` |
| `MeterProvider::meter` | `(name~ : String, version? : String, attributes?) -> Meter` |
| `MeterProvider::collect` | `(at~ : Int64) -> Array[Metric]` — run the callbacks, then the points as they stand, without writing them |
| `MeterProvider::emit` | `(at~ : Int64) -> Array[Metric]` — collect, write every metric to the sink, and clear a delta reader |
| `Meter::counter`, `up_down_counter`, `gauge` | `(name, description?, unit?) -> … raise Refused` |
| `Meter::histogram` | `(name, description?, unit?, bounds? : Array[Double]) -> Histogram raise Refused` |
| `Meter::exponential_histogram` | `(name, description?, unit?, scale? : Int32, max_buckets? : Int32) -> ExponentialHistogram raise Refused` |
| `Meter::observable_counter`, `observable_up_down_counter`, `observable_gauge` | `(name, description?, unit?, observe~ : (Observer) -> Unit) -> … raise Refused` |
| `Observer::observe` | `(value : Double, attributes?, at? : Int64, context? : TraceContext)` — one series' value at this collection |
| `Counter::add`, `inc` | `(value : Double, attributes?, at? : Int64, context? : TraceContext)` — `inc` adds one |
| `UpDownCounter::add` | `(value : Double, attributes?, at?, context?)` — either sign |
| `Gauge::set` | `(value : Double, attributes?, at?, context?)` — the last value wins |
| `Histogram::record`, `ExponentialHistogram::record` | `(value : Double, attributes?, at?, context?)` — into the bucket that contains it |
| `View::new` | `(instrument~ : String, kind? : InstrumentKind, name?, description?, attribute_keys? : Array[String], aggregation? : Aggregation) -> View` |
| `Aggregation` | `Sum`, `LastValue`, `ExplicitBuckets(bounds)`, `ExponentialBuckets(scale, max_buckets)`, `Drop` |
| `ExemplarFilter` | `TraceBased` (the default), `AlwaysOn`, `AlwaysOff` |
| `Attributes` | `new`, `with_attribute`, `get`, `to_array`, `len`, `identity` |
| `gen_ai_client_attributes` | `(provider~, operation~, request_model~, response_model?, agent_name?, conversation_id?) -> Attributes` |
| `MeterLimits` | `attributes 128, series 2000, exemplars 1, attribute_value_length` |
| `default_buckets`, `max_exponential_buckets` | the metrics SDK's fifteen boundaries and its 160-bucket default |
| `exponential_index`, `exponential_bucket_count`, `max_exponential_scale`, `min_exponential_scale` | the bucket rule, and the scale range the SDK defines |
| `InstrumentKind`, `Refused` | what a name is registered as, and why a name or a bucket list was refused |

### `otlp` — the export

| Item | Signature |
|:--|:--|
| `TraceExporter::new` | `(transport~ : &Transport, endpoint? : String, headers?, resource? : Resource, scope? : Scope, policy? : BatchPolicy, backoff? : Backoff, attempts? : Int32, now~ : () -> Int64, rand~ : (Int32) -> Bytes) -> TraceExporter` |
| `LogsExporter::new`, `MetricsExporter::new` | the same shape for the other two signals |
| `flush`, `tick`, `run` | send everything, send what is due, keep sending |
| `Report`, `Stats` | `delivered, rejected, dropped, attempts` per flush, and since the exporter was made |
| `BatchPolicy` | `queue_limit 2048, batch 512, delay 5000, timeout 30000` |
| `BodyLimits` | `request 64 MiB, response 4 MiB` — the protocol's recommended sizes |
| `Encoding` | `format`, `traces`, `logs`, `metrics`, `rejected` — how a body is written |
| `json` | the JSON encoding, which is what an exporter writes unless told otherwise |
| `BodyFormat` | `Json`, `Protobuf` — what an encoding reports, and the media type that follows |
| `Backoff` | `initial 5000, multiplier 1.5, maximum 30000, jitter 0.2` |
| `Transport` | `async fn send(Self, Request) -> Reply raise Failed` |
| `Resource`, `Scope` | what produced the telemetry, and which library in it did |
| `Metric`, `MetricKind`, `DataPoint`, `Point`, `Temporality`, `Exemplar` | the OTLP metric shapes, for a producer that has its own numbers |
| `MetricSink` | `accept(Metric) -> Unit` — where a producer writes finished metrics |
| `MetricRecorder` | `new`, `metrics`, `len`, `take` — the metrics kept in memory |

### `otlp/http`, `otlp/p8s`, `semconv`

| Item | Signature |
|:--|:--|
| `HttpTransport::new` | `(timeout? : Int32, compression? : Compression) -> HttpTransport` |
| `otlp/grpc.GrpcTransport::connect` | `(host~ : String, port? : Int32, encoding?) -> GrpcTransport` — one unary call per request |
| `otlp/binary.protobuf` | `&Encoding` — the binary body, and the messages it is made of |
| `otlp/binary.encode_traces`, `encode_logs`, `encode_metrics` | `(records, resource~, scope~) -> Bytes` — a body without an exporter |
| `Compression` | `Plain`, `Gzip` — the second sets `Content-Encoding` on the request |
| `bridge`, `bridge_with_report` | `(families : Array[MetricFamily], at~ : Int64, start? : Int64) -> Array[Metric]` — and the same with what was dropped |
| `gen_ai_request_model`, `gen_ai_client_inference_duration`, … | 85 attribute keys, 21 metric names, 13 span types and 11 event names |

## Limits

A span keeps at most 128 attributes, 128 events and 128 links, and an event at most 128
attributes. Past that a write is dropped and counted in `SpanData::dropped`, so a
runaway loop of attributes cannot take the process down with it. `Limits` changes the
numbers, including a maximum length for string values.

An exponential histogram keeps at most 160 buckets, the metrics SDK's default: past
that the buckets merge in pairs and the scale drops, down to `-10`, which is as coarse
as the SDK defines.

`tracestate` holds at most 32 members, a key at most 256 characters and a value at most
256; `baggage` at most 64 members and 8192 octets of header. These are the limits the
two specifications state, and a header past them is refused rather than truncated.

A `tracestate` key is read as the W3C interoperability suite reads it — a lowercase
letter or a digit, then up to 255 characters from `a-z`, `0-9`, `_`, `-`, `*`, `/` and
`@` — rather than as the narrower multi-tenant grammar of the specification, so `foo@`
and `foo@@bar` travel through. A key that starts with `@`, carries anything else, or
runs past 256 characters still drops the header.

## Conformance

- **W3C Trace Context.** The official suite in `integration/trace-context` drives a hop
  built on this library, and every case passes.
- **OTLP.** `otel/opentelemetry-collector-contrib` 0.164.0 decodes spans, log records
  and metrics on HTTP/JSON, HTTP/JSON with gzip, HTTP/protobuf and gRPC. The CI job
  reads the collector's log and counts each item on each transport.
- **Metrics.** `weaver registry live-check` runs against two registries. Against
  `integration/weaver/registry`, which describes the seven metrics of
  `src/examples/06-meter`, it reports seven metrics, seven data points, registry
  coverage 1.0 and no advisory. Against the GenAI semantic conventions pinned at
  `aa3b7f4` it recognises `gen_ai.client.operation.duration` and the four GenAI
  attributes. Seven violations remain, and they are known: the six demonstration names
  (`gen_ai.client.token.usage`, `gen_ai.client.active.requests`,
  `gen_ai.client.queue.length`, `gen_ai.client.tokens.reported`,
  `gen_ai.client.workers.reported`, `moontel.example.latency`) are not in that
  registry, and `service.name` is a resource attribute it does not define. The
  remaining improvements are stability levels — every GenAI metric and attribute is
  still `development` upstream — and the optional `server.address`, `server.port` and
  conditional `error.type` attributes.

## What this is not

- **No storage, no query, no page.** A collector or a hosted backend reads what this
  sends.
- **No clock, no sockets, no framework.** A tracer is handed its times, its ids and its
  destination; a meter is handed its clock; a transport is handed a request.

## Examples

```
moon run src/examples/00-hello        # a root span, a child, attributes and an event
moon run src/examples/01-propagate    # reading a request's context, writing the next one's
moon run src/examples/02-asgi         # the middleware over an application
moon run src/examples/03-annotated    # the annotation, and the wrapper it generates
moon run src/examples/04-otlp         # three signals, to a collector
moon run src/examples/05-grpc         # the same three signals, over gRPC
moon run src/examples/06-meter        # observed instruments, views and an exponential histogram
```

## Licence

Apache-2.0.

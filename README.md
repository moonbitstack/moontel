<h1 align="center">moontel</h1>

<p align="center"><em>OpenTelemetry tracing for MoonBit.</em></p>

<p align="center">
  <a href="https://moonbitstack.github.io/moontel/"><b>Home</b></a> ·
  <a href="https://moonbitstack.github.io/moontel/guide.html"><b>Guide</b></a> ·
  <a href="https://moonbitstack.github.io/moontel/api.html"><b>API</b></a> ·
  <a href="https://mooncakes.io/docs/moonbitstack/moontel"><b>mooncakes</b></a>
</p>

---

Distributed tracing for MoonBit: spans, the samplers that decide which of them to
keep, and the headers that carry a trace from one service to the next.

A request that touches five services is one trace with a tree of spans, and every
service has to agree on the same names, the same ids and the same wire format for
that to be readable. This library is that agreement: it builds the spans, decides
what to keep, and reads and writes the headers the agreement is written in —
`traceparent` and `tracestate` from W3C Trace Context, and `baggage` from W3C
Baggage.

The [documentation site](https://moonbitstack.github.io/moontel/) has a guide, the
complete reference, a showcase you can play with, and three runnable examples.

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

## The two seams

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
wants. Anything else — OTLP over HTTP, a file, a queue a background task drains — is a
`Sink` of your own, and the transport stays yours.

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

## The interface

Three packages, plus a facade that re-exports them. Import the package that owns the
type you construct — an enum constructor is reached through the package that defines
it, not through the facade.

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

## Limits

A span keeps at most 128 attributes, 128 events and 128 links, and an event at most 128
attributes. Past that a write is dropped and counted in `SpanData::dropped`, so a
runaway loop of attributes cannot take the process down with it. `Limits` changes the
numbers, including a maximum length for string values.

`tracestate` holds at most 32 members, a key at most 256 characters and a value at most
256; `baggage` at most 64 members and 8192 octets of header. These are the limits the
two specifications state, and a header past them is refused rather than truncated.

A `tracestate` key is read as the W3C interoperability suite reads it — a lowercase
letter or a digit, then up to 255 characters from `a-z`, `0-9`, `_`, `-`, `*`, `/` and
`@` — rather than as the narrower multi-tenant grammar of the specification, so `foo@`
and `foo@@bar` travel through. A key that starts with `@`, carries anything else, or
runs past 256 characters still drops the header.

## What this is not

- **No OTLP export.** A `Sink` is the seam; a sink that speaks OTLP over HTTP is the
  next piece of work, and does not belong in the tracing model.
- **No metrics and no logs.** Those are separate signals with their own shapes.
- **No clock, no sockets, no framework.** A tracer is handed its times, its ids and its
  destination.

## Examples

```
moon run src/examples/00-hello        # a root span, a child, attributes and an event
moon run src/examples/01-propagate    # reading a request's context, writing the next one's
moon run src/examples/02-asgi         # the middleware over an application
```

## Licence

Apache-2.0.

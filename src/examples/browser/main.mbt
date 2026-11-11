// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Runs the library for the picture the home page draws, and leaves the result where
/// the page can read it.
///
/// Nothing on the page invents a span, an id or a decision: the trace below is made
/// by a `Tracer` with a `Recorder` sink and read back as what a sink received, and the
/// sampling strip asks `ratio` about every id at the moment the reader moves the
/// control. The page does layout; the library does tracing.
///
///     moon build --target js src/examples/browser
extern "js" fn publish(text : String) -> Unit =
  #|(text) => { globalThis.moontelTrace = JSON.parse(text) }

///|
/// Hands the page one callable: the sampler, over the ids in the strip.
extern "js" fn expose_sampler(f : (Double) -> String) -> Unit =
  #|(f) => { globalThis.moontelKept = (ratio) => JSON.parse(f(ratio)) }

///|
/// The ids the tracer is handed, in the order it asks for them: one trace id and then
/// one span id per span. Fixed, so the picture is the same on every visit — a page
/// that reshuffled its own artwork on reload would be showing off a random number
/// generator rather than this library.
let hero_ids : Array[Bytes] = [
  b"\x1c\x9d\x4f\x7a\x2b\x8e\x53\x06\xad\x41\xc7\xe9\xb0\x2f\x6d\x38", b"\xa7\x12\x3e\x9b\x54\xd8\x60\x1f",
  b"\x6e\x3b\x18\xc2\xf7\x05\x9a\x44", b"\x0d\x84\x5a\xe1\x37\xc9\x2b\x76", b"\xf2\x57\x0c\x93\x48\xae\x1d\x6b",
  b"\x35\xc8\x42\x7f\x16\xe0\x8d\x29", b"\xba\x0e\x67\xd4\x29\x83\x5c\xf1", b"\x4d\x91\x2a\xf6\x03\xb8\x7e\x55",
]

///|
/// Hands out `hero_ids` in order, then repeats the last one: the tracer is expected to
/// ask exactly this many times for this picture.
fn scripted_rand() -> (Int32) -> Bytes {
  let next = Ref(0)
  width => {
    let index = next.val
    next.val = next.val + 1
    if index < hero_ids.length() {
      hero_ids[index]
    } else {
      Bytes::make(width, b'\x2a')
    }
  }
}

///|
/// One request through five services, timed in microseconds from its start. The shape
/// is the point: one span opens the request, four things happen inside it, and one of
/// those four waits on a database of its own.
///
/// The times are handed in, because the library never reads a clock — which is also
/// why this picture is the same everywhere and on every run. The header comes back
/// out of the root span, so the specimen the page sets in type is one the library
/// wrote.
fn hero_trace() -> (@trace.Recorder, String) {
  let recorder = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=scripted_rand(),
    sink=recorder,
    sampler=@trace.always,
  )
  let root = tracer.start("GET /orders", kind=@trace.Server, at=0L, attributes=[
    ("http.request.method", @trace.Str("GET")),
    ("url.path", @trace.Str("/orders")),
    ("http.response.status_code", @trace.Int(200L)),
  ]) catch {
    _ => abort("the scripted ids are not ids")
  }
  let validate = tracer.start(
    "validate cart",
    parent=root.context(),
    at=1_100_000L,
    attributes=[("cart.items", @trace.Int(3L))],
  ) catch {
    _ => abort("the scripted ids are not ids")
  }
  validate.finish(at=4_600_000L)
  let query = tracer.start(
    "SELECT orders",
    parent=root.context(),
    kind=@trace.Client,
    at=5_200_000L,
    attributes=[
      ("db.system", @trace.Str("postgresql")),
      ("db.rows", @trace.Int(3L)),
    ],
  ) catch {
    _ => abort("the scripted ids are not ids")
  }
  query.finish(at=21_300_000L)
  let reserve = tracer.start(
    "POST inventory/reserve",
    parent=root.context(),
    kind=@trace.Client,
    at=21_900_000L,
    attributes=[("server.address", @trace.Str("inventory.internal"))],
  ) catch {
    _ => abort("the scripted ids are not ids")
  }
  let stock = tracer.start(
    "UPDATE stock",
    parent=reserve.context(),
    kind=@trace.Client,
    at=22_400_000L,
    attributes=[("db.rows", @trace.Int(1L))],
  ) catch {
    _ => abort("the scripted ids are not ids")
  }
  stock.finish(at=26_800_000L)
  reserve.finish(at=31_200_000L)
  let publish = tracer.start(
    "publish order.created",
    parent=root.context(),
    kind=@trace.Producer,
    at=31_400_000L,
    attributes=[("messaging.destination", @trace.Str("order.created"))],
  ) catch {
    _ => abort("the scripted ids are not ids")
  }
  publish.finish(at=32_100_000L)
  root.add_event("cache.miss", at=5_150_000L)
  let header = root.context().to_traceparent()
  root.finish(at=38_400_000L)
  (recorder, header)
}

///|
/// The trace as the page reads it: what a sink received, in the order it received it,
/// plus the header the root span produced and the ids behind the sampling strip.
fn trace_json() -> Json {
  let (recorder, header) = hero_trace()
  let spans = recorder.spans()
  let mut dropped = 0
  for span in spans {
    dropped = dropped +
      span.dropped.attributes +
      span.dropped.events +
      span.dropped.links
  }
  Json::object({
    "traceparent": Json::string(header),
    "duration_us": Json::number(38_400.0),
    "dropped": Json::number(dropped.to_double()),
    "spans": Json::array(
      spans.map(fn(span) {
        let attributes : Array[Json] = span.attributes.map(fn(pair) {
          Json::array([Json::string(pair.0), Json::string(value_text(pair.1))])
        })
        let events : Array[Json] = span.events.map(fn(event) {
          Json::array([
            Json::string(event.name),
            Json::number(event.at.to_double() / 1000.0),
          ])
        })
        Json::object({
          "id": Json::string(encode_id(span.context.span_id)),
          "parent": match span.parent {
            Some(id) => Json::string(encode_id(id))
            None => Json::null()
          },
          "name": Json::string(span.name),
          "kind": Json::string(kind_text(span.kind)),
          "start": Json::number(span.start.to_double() / 1000.0),
          "end": Json::number(span.end.to_double() / 1000.0),
          "sampled": Json::boolean(span.sampled()),
          "attributes": Json::array(attributes),
          "events": Json::array(events),
        })
      }),
    ),
    "strip": Json::array(strip_ids_json()),
  })
}

///|
/// How many requests the strip holds. At five hundred the proportion the sampler
/// keeps is the proportion it says, which ninety-six ids drawn from one stretch of a
/// counter are not: a sample that small reads a tenth as a sixth by chance alone.
let strip_width : Int32 = 512

///|
/// The strip: which of the ids a sampler keeps at a given ratio.
///
/// The ids are the same on every call, so raising the ratio can be watched keeping
/// everything the lower one kept — which is the property a ratio sampler has and a
/// coin toss does not.
fn kept_json(ratio : Double) -> String {
  let sampler = @trace.ratio(ratio~)
  let kept : Array[Json] = []
  for i in 0..<strip_width {
    let decision = sampler.should_sample({
      parent: None,
      trace_id: strip_id(i),
      name: "GET /orders",
      kind: @trace.Server,
    })
    kept.push(Json::boolean(decision == @trace.RecordAndSample))
  }
  Json::object({ "kept": Json::array(kept) }).stringify()
}

///|
/// The ids behind the strip, so the page can name one when the pointer rests on it.
fn strip_ids_json() -> Array[Json] {
  let ids : Array[Json] = []
  for i in 0..<strip_width {
    ids.push(Json::string(encode_id(strip_id(i))))
  }
  ids
}

///|
/// The trace id of the `i`th request in the strip.
///
/// These are names for marks, not entropy: a seeded mixer gives the same ninety-six
/// ids on every visit, so the picture does not reshuffle. The decision the page shows
/// is not made here — it is `ratio`, asked about each of these ids.
fn strip_id(i : Int32) -> Bytes {
  let high = mix(i.to_int64().reinterpret_as_uint64())
  let low = mix(high ^ 0x9E3779B97F4A7C15UL)
  let bytes : Array[Byte] = []
  push_be(bytes, high)
  push_be(bytes, low)
  Bytes::from_array(bytes)
}

///|
/// One 64-bit word as its eight big-endian octets.
fn push_be(bytes : Array[Byte], value : UInt64) -> Unit {
  bytes.push(((value >> 56) & 0xFFUL).to_byte())
  bytes.push(((value >> 48) & 0xFFUL).to_byte())
  bytes.push(((value >> 40) & 0xFFUL).to_byte())
  bytes.push(((value >> 32) & 0xFFUL).to_byte())
  bytes.push(((value >> 24) & 0xFFUL).to_byte())
  bytes.push(((value >> 16) & 0xFFUL).to_byte())
  bytes.push(((value >> 8) & 0xFFUL).to_byte())
  bytes.push((value & 0xFFUL).to_byte())
}

///|
/// SplitMix64's finaliser (Steele, Lea, Flood): cheap, and it spreads consecutive
/// counters far enough apart that neighbouring marks do not fall on the same side of
/// every threshold.
fn mix(value : UInt64) -> UInt64 {
  let mut z = value + 0x9E3779B97F4A7C15UL
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}

///|
/// An id in the spelling the header uses.
fn encode_id(id : Bytes) -> String {
  let out = StringBuilder()
  for byte in id {
    let value = byte.to_int()
    out.write_char(hex_char(value >> 4))
    out.write_char(hex_char(value & 0x0f))
  }
  out.to_string()
}

///|
fn hex_char(value : Int32) -> Char {
  if value < 10 {
    (0x30 + value).unsafe_to_char()
  } else {
    (0x61 + value - 10).unsafe_to_char()
  }
}

///|
fn kind_text(kind : @trace.SpanKind) -> String {
  match kind {
    Internal => "Internal"
    Server => "Server"
    Client => "Client"
    Producer => "Producer"
    Consumer => "Consumer"
  }
}

///|
/// An attribute value as the page prints it. The marginalia shows values as text, so
/// the numbers keep the spelling they were set with.
fn value_text(value : @trace.Value) -> String {
  match value {
    Bool(v) => v.to_string()
    Int(v) => v.to_string()
    Double(v) => v.to_string()
    Str(v) => v
    Bools(vs) => "[" + vs.map(v => v.to_string()).join(",") + "]"
    Ints(vs) => "[" + vs.map(v => v.to_string()).join(",") + "]"
    Doubles(vs) => "[" + vs.map(v => v.to_string()).join(",") + "]"
    Strs(vs) => "[" + vs.join(",") + "]"
  }
}

///|
fn main {
  publish(trace_json().stringify())
  expose_sampler(kept_json)
  expose_distribution(distribution_json)
  expose_parse(parse_json)
  expose_hop(hop_json)
}

///|
/// Hands the page the strict parser: one header in, what the library read or why it
/// refused it out.
extern "js" fn expose_parse(f : (String) -> String) -> Unit =
  #|(f) => { globalThis.moontelParse = (text) => JSON.parse(f(text)) }

///|
/// Hands the page one hop: a parent header and vendor state in, the headers this hop
/// would send on out.
extern "js" fn expose_hop(f : (String, String) -> String) -> Unit =
  #|(f) => { globalThis.moontelHop = (parent, state) => JSON.parse(f(parent, state)) }

///|
/// The parser's answer as the showcase reads it: the ids and flags, or the offset and
/// shape that made it refuse.
fn parse_json(text : String) -> String {
  let context = @propagate.parse(text[:]) catch {
    error => return refusal_json(error)
  }
  Json::object({
    "ok": Json::boolean(true),
    "trace_id": Json::string(encode_id(context.trace_id)),
    "span_id": Json::string(encode_id(context.span_id)),
    "flags": Json::string(hex_byte(context.flags)),
    "sampled": Json::boolean(context.sampled()),
    "random": Json::boolean((context.flags & @trace.random_flag) != b'\x00'),
    "valid": Json::boolean(context.is_valid()),
  }).stringify()
}

///|
/// A refusal, with the offset and the shape the parser wanted. The variants without a
/// position report -1 so the page has one number to place in every case.
fn refusal_json(error : @trace.Refused) -> String {
  let (kind, at, want, got, limit) = match error {
    Field(at~, want~) => ("field", at, want, 0, 0)
    NotHex(at~) =>
      ("not hexadecimal", at, "a lowercase hexadecimal digit", 0, 0)
    Zero(at~) => ("zero id", at, "an id that is not all zero", 0, 0)
    TooMany(limit~, got~) => ("too many", -1, "fewer members", got, limit)
    TooLong(limit~, got~) => ("too long", -1, "a shorter header", got, limit)
    Ids(want~, got~) =>
      ("bad id source", -1, "an id of the width asked for", got, want)
  }
  Json::object({
    "ok": Json::boolean(false),
    "kind": Json::string(kind),
    "at": Json::number(at.to_double()),
    "want": Json::string(want),
    "got": Json::number(got.to_double()),
    "limit": Json::number(limit.to_double()),
  }).stringify()
}

///|
/// One hop, through the library: take the context off the request, open a server span
/// under it, and inject the headers this hop would send on.
fn hop_json(parent : String, state : String) -> String {
  let headers : Array[(String, String)] = [("traceparent", parent)]
  if state.length() > 0 {
    headers.push(("tracestate", state))
  }
  let extracted = @propagate.extract(headers)
  let tracer = @trace.Tracer::new(
    rand=hop_rand(),
    sink=@trace.Discard::{ },
    sampler=@trace.parent_based(root=@trace.always),
  )
  let span = match extracted.context {
    Some(context) =>
      tracer.start("GET /orders/42", parent=context, kind=@trace.Server, at=0L) catch {
        _ =>
          return hop_failed(
            "\{parent} did not carry a context this tracer could join",
          )
      }
    None =>
      tracer.start("GET /orders/42", kind=@trace.Server, at=0L) catch {
        _ =>
          return hop_failed(
            "\{parent} did not carry a context this tracer could join",
          )
      }
  }
  let outgoing = @propagate.inject([], {
    context: Some(span.context()),
    baggage: extracted.baggage,
  })
  span.finish(at=1L)
  let sent = header_value(outgoing, "traceparent")
  let sent_state = header_value(outgoing, "tracestate")
  Json::object({
    "ok": Json::boolean(true),
    "traceparent": Json::string(sent),
    "trace_id": Json::string(encode_id(span.context().trace_id)),
    "span_id": Json::string(encode_id(span.context().span_id)),
    "parent_span_id": match extracted.context {
      Some(context) => Json::string(encode_id(context.span_id))
      None => Json::null()
    },
    "linked": Json::boolean(extracted.context is Some(_)),
    "tracestate": Json::string(sent_state),
    "tracestate_kept": Json::boolean(state.length() > 0 && sent_state == state),
    "headers": Json::array(
      outgoing.map(fn(pair) {
        Json::array([Json::string(pair.0), Json::string(pair.1)])
      }),
    ),
  }).stringify()
}

///|
fn hop_failed(reason : String) -> String {
  Json::object({ "ok": Json::boolean(false), "reason": Json::string(reason) }).stringify()
}

///|
/// The one header of `name` in a list, or "" when it is not there.
fn header_value(headers : Array[(String, String)], name : String) -> String {
  for pair in headers {
    if pair.0 == name {
      return pair.1
    }
  }
  ""
}

///|
/// A byte as the two lowercase hexadecimal characters the header uses.
fn hex_byte(value : Byte) -> String {
  let n = value.to_int()
  let out = StringBuilder()
  out.write_char(hex_char(n >> 4))
  out.write_char(hex_char(n & 0x0f))
  out.to_string()
}

///|
/// A source of ids for one hop: fixed, so the outgoing span id is the same on every
/// visit and the page can point at what changed. The width is honoured, because a hop
/// with no parent needs a trace id as well as a span id.
fn hop_rand() -> (Int32) -> Bytes {
  let call = Ref(0)
  width => {
    call.val = call.val + 1
    let bytes : Array[Byte] = []
    for i in 0..<width {
      bytes.push((0x40 + call.val * 7 + i).to_byte())
    }
    Bytes::from_array(bytes)
  }
}

///|
/// Hands the page the distribution: one set of latencies, counted two ways.
extern "js" fn expose_distribution(f : (Double) -> String) -> Unit =
  #|(f) => { globalThis.moontelDistribution = (spread) => JSON.parse(f(spread)) }

///|
/// How many requests the picture counts. A number large enough that the shape is the
/// shape and not the noise of a small sample, and small enough to compute while the
/// reader drags the control.
let spectrum_size : Int32 = 512

///|
/// The boundaries of the explicit histogram: the ones a person picks when they think
/// they know what a request costs. Nine buckets, from ten milliseconds to two and a
/// half seconds.
let spectrum_bounds : Array[Double] = [
  0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5,
]

///|
/// The span a measurement made on this page belongs to, so the exemplar the chart
/// marks names a trace the rest of the sheet also draws.
let spectrum_span : @trace.TraceContext = @trace.TraceContext::new(
  trace_id=b"\x1c\x9d\x4f\x7a\x2b\x8e\x53\x06\xad\x41\xc7\xe9\xb0\x2f\x6d\x38",
  span_id=b"\xa7\x12\x3e\x9b\x54\xd8\x60\x1f",
  flags=@trace.sampled_flag,
)

///|
/// The `i`th request's latency, in seconds, at this spread.
///
/// A log-normal is what a latency distribution looks like: mostly near the median,
/// with a tail that reaches far right. `spread` multiplies the standard deviation of
/// the logarithm, so the control widens the distribution rather than moving it. The
/// last request is the slowest one, which is why the exemplar marks it.
fn spectrum_latency(i : Int32, spread : Double) -> Double {
  let z = if i == spectrum_size - 1 {
    3.2
  } else {
    normal(mix(i.to_int64().reinterpret_as_uint64()))
  }
  0.05 * @math.exp(spread * 1.4 * z)
}

///|
/// A standard normal from a 64-bit word: Box-Muller on two uniforms taken from the
/// two halves, which is enough for a picture and does not need a source of entropy.
fn normal(word : UInt64) -> Double {
  let high = (word >> 11).to_double() / 9007199254740992.0
  let low = (word & 0x1FFFFFFFFFFFFFUL).to_double() / 9007199254740992.0
  let u = if high <= 0.0 { 1.0e-12 } else { high }
  let v = if low <= 0.0 { 1.0e-12 } else { low }
  (-2.0 * @math.ln(u)).sqrt() * @math.cos(6.283185307179586 * v)
}

///|
/// One distribution, two histograms, as the page reads it: the bucket counts, the
/// scale the exponential one settled on, and the exemplar of the slowest request.
fn distribution_json(spread : Double) -> String {
  let provider = @meter.MeterProvider::new(
    sink=@otlp.MetricRecorder::new(),
    now=() => 0L,
    current=() => Some(spectrum_span),
  )
  let meter = provider.meter(name="moontel-showcase")
  let explicit = meter.histogram(
    "request.duration",
    unit="s",
    bounds=spectrum_bounds,
  ) catch {
    _ => abort("the showcase boundaries are not boundaries")
  }
  let exponential = meter.exponential_histogram(
    "request.duration.adaptive",
    unit="s",
  ) catch {
    _ => abort("the showcase instrument name was refused")
  }
  for i in 0..<spectrum_size {
    let value = spectrum_latency(i, spread)
    explicit.record(value, at=0L)
    // Only the slowest request carries its span: the library keeps one exemplar per
    // series, and the reader wants to know which request filled the tail.
    if i == spectrum_size - 1 {
      exponential.record(value, at=0L, context=spectrum_span)
    } else {
      exponential.record(value, at=0L)
    }
  }
  let metrics = provider.collect(at=1_000_000L)
  let explicit_json = match metrics[0].points[0].point {
    @otlp.Buckets(bounds~, counts~, sum~, count~, min~, max~) =>
      Json::object({
        "bounds": Json::array(bounds.map(fn(value) { Json::number(value) })),
        "counts": Json::array(
          counts.map(fn(value) { Json::number(value.to_double()) }),
        ),
        "sum": Json::number(sum),
        "count": Json::number(count.to_double()),
        "min": Json::number(min.unwrap_or(0.0)),
        "max": Json::number(max.unwrap_or(0.0)),
      })
    _ => Json::null()
  }
  let exponential_json = match metrics[1].points[0].point {
    @otlp.ExponentialBuckets(
      scale~,
      positive_offset~,
      positive_counts~,
      zero_count~,
      count~,
      sum~,
      ..
    ) =>
      Json::object({
        "scale": Json::number(scale.to_double()),
        "offset": Json::number(positive_offset.to_double()),
        "counts": Json::array(
          positive_counts.map(fn(value) { Json::number(value.to_double()) }),
        ),
        "zero": Json::number(zero_count.to_double()),
        "count": Json::number(count.to_double()),
        "sum": Json::number(sum),
      })
    _ => Json::null()
  }
  let exemplar_json = match metrics[1].points[0].exemplars {
    [exemplar, ..] =>
      Json::object({
        "trace": Json::string(encode_id(exemplar.trace_id.unwrap_or(b""))),
        "span": Json::string(encode_id(exemplar.span_id.unwrap_or(b""))),
        "value": Json::number(exemplar.value),
      })
    [] => Json::null()
  }
  Json::object({
    "explicit": explicit_json,
    "exponential": exponential_json,
    "exemplar": exemplar_json,
    "requests": Json::number(spectrum_size.to_double()),
  }).stringify()
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One span, over OTLP/gRPC: the same payload the HTTP example sends, carried by a
/// unary call on a channel that stays open.
///
///     moon run src/examples/05-grpc --target native
///     moon run src/examples/05-grpc --target native -- localhost:4317
///
/// The argument is `host:port`, because that is what a channel connects to; the
/// protocol puts the gRPC port at 4317. With one on the command line the program
/// requires the collector to be there and exits non-zero when the span could not be
/// delivered, which is what the conformance job in CI runs.
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
  let transport = @grpc.GrpcTransport::connect(host~, port~)
  // gRPC carries the binary encoding only, so the exporter is built for it. The
  // endpoint is still a URL: it names the signal, and the transport turns
  // `/v1/traces` into the method the collector serves.
  let traces = @otlp.TraceExporter::new(
    transport~,
    endpoint="http://\{address}",
    resource=@otlp.Resource::of_service("moontel-example"),
    format=@otlp.BodyFormat::Protobuf,
    now=millis,
    rand=random_bytes,
    attempts=if required { 5 } else { 1 },
  )
  let tracer = @trace.Tracer::new(
    sink=traces,
    rand=random_bytes,
    sampler=@trace.always,
  )
  let started = millis()
  let span = tracer.start(
    "PUT /orders/42/ship",
    kind=@trace.Server,
    at=started,
    attributes=[("http.request.method", @trace.Str("PUT"))],
  ) catch {
    _ => abort("the platform has no entropy source")
  }
  span.set_attribute("http.response.status_code", @trace.Int(204L))
  span.set_status(@trace.Ok)
  span.finish(at=started + 2_000_000L)
  let report = traces.flush()
  transport.close()
  println(
    "gRPC: delivered \{report.delivered}, rejected \{report.rejected}, dropped \{report.dropped}, requests \{report.attempts}",
  )
  if required && report.delivered != 1 {
    println("a collector was named at \{address} and did not take the span")
    abort("the span was not delivered")
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
/// The clock the exporter uses for batching and for the retry budget. The runtime's
/// is monotonic, which is what those two need.
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

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A transport that speaks OTLP over gRPC: one unary call per request, on a channel
/// that stays open between them.
///
/// The protocol's two transports take the same payloads, so this is a different
/// `Transport` over the same exporters: the queue, the batch, the retry rules and
/// the size bounds are the ones `otlp` already has, and only the way a request
/// travels is different.
///
/// gRPC carries the binary protobuf encoding and nothing else, so an exporter
/// built on this transport must be built with `format=Protobuf`. A request that
/// says `application/json` is refused here rather than sent to a server that would
/// answer with a decode error nobody can act on.
pub struct GrpcTransport {
  channel : @net.Channel
}

///|
/// Connect to a collector's gRPC port, which the protocol puts at 4317.
///
/// The channel is one long-lived HTTP/2 connection that every call multiplexes
/// over, so a program makes one of these and keeps it. `encoding` is the message
/// compression the channel offers, and it is not the same thing as the request
/// body: gRPC compresses a message itself, with a flag byte in front of it.
pub async fn GrpcTransport::connect(
  host~ : String,
  port~ : Int32 = 4317,
  encoding? : @moonrpc.Encoding,
) -> GrpcTransport {
  { channel: @net.Channel::connect(host, port, encoding?), }
}

///|
/// Close the channel. A channel left open keeps a socket and a reader task alive.
pub fn GrpcTransport::close(self : GrpcTransport) -> Unit {
  self.channel.close()
}

///|
/// One export, as a unary call.
pub impl @otlp.Transport for GrpcTransport with fn send(self, request) {
  self.call(request)
}

///|
pub extend GrpcTransport with @otlp.Transport::{send}

///|
/// The request as a call, and the call's status as the HTTP status the retry rules
/// are written against.
async fn GrpcTransport::call(
  self : GrpcTransport,
  request : @otlp.Request,
) -> @otlp.Reply raise @otlp.Failed {
  require_protobuf(request.headers)
  let path = service_path(request.url)
  let metadata = metadata_of(request.headers)
  let answer = Ok(self.channel.unary(path, request.body, metadata~)) catch {
    error => Err("\{error}")
  }
  match answer {
    Ok(reply) => {
      // A gRPC reply is zero or one message; a `partial_success` is inside it, in
      // the same protobuf the request was written in.
      let body = if reply.messages.is_empty() { b"" } else { reply.messages[0] }
      { status: status_of(reply.grpc_status), headers: [], body, }
    }
    Err(reason) => raise @otlp.Failed::Unreachable(reason~)
  }
}

///|
/// The request headers as call metadata.
///
/// The content type is left out on purpose: what the body is, gRPC decides, and it
/// announces `application/grpc` itself. Sending ours along would replace that and
/// the server would refuse the call before reading a byte of it — status 13, with a
/// message that says nothing about why.
fn metadata_of(headers : Array[(String, String)]) -> Array[@header.Header] {
  let metadata : Array[@header.Header] = []
  for header in headers {
    if header.0.to_lower() != "content-type" {
      metadata.push(@header.Header::of(header.0, header.1))
    }
  }
  metadata
}

///|
/// The gRPC method an OTLP/HTTP path names, since the exporters build the URL the
/// HTTP transport wants and this one needs the method on the other side of it.
fn service_path(url : String) -> String raise @otlp.Failed {
  if url.has_suffix("/v1/traces") {
    "/opentelemetry.proto.collector.trace.v1.TraceService/Export"
  } else if url.has_suffix("/v1/metrics") {
    "/opentelemetry.proto.collector.metrics.v1.MetricsService/Export"
  } else if url.has_suffix("/v1/logs") {
    "/opentelemetry.proto.collector.logs.v1.LogsService/Export"
  } else {
    raise @otlp.Failed::Unreachable(
      reason="no gRPC method for \{url}: expected /v1/traces, /v1/metrics or /v1/logs",
    )
  }
}

///|
/// The HTTP status a gRPC status stands for, so the one set of retry rules serves
/// both transports.
///
/// The protocol names the same three situations in both: a server that is busy, one
/// that is being throttled, and one that ran out of time. Mapping them onto the
/// statuses the rules already know is cheaper than teaching the retry loop a second
/// vocabulary — and `verdict` is where the vocabulary lives.
fn status_of(grpc_status : Int32) -> Int32 {
  match grpc_status {
    0 => 200 // OK
    8 => 429 // RESOURCE_EXHAUSTED
    14 => 503 // UNAVAILABLE
    4 => 504 // DEADLINE_EXCEEDED
    _ => 400 // anything else is this request's problem, and a retry repeats it
  }
}

///|
/// gRPC carries protobuf and nothing else, so a request built for JSON is refused
/// here: the server would answer with a decode error that says less than this does.
fn require_protobuf(
  headers : Array[(String, String)],
) -> Unit raise @otlp.Failed {
  let refused = @otlp.Failed::Unreachable(
    reason="gRPC carries protobuf only: build the exporter with format=Protobuf",
  )
  match content_type(headers) {
    Some(value) =>
      if value.to_lower() != "application/x-protobuf" {
        raise refused
      }
    None => raise refused
  }
}

///|
fn content_type(headers : Array[(String, String)]) -> String? {
  for header in headers {
    if header.0.to_lower() == "content-type" {
      return Some(header.1)
    }
  }
  None
}

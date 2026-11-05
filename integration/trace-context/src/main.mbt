// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The service the W3C Trace Context conformance suite drives.
///
///     moon run src --target native -- 8080
///
/// The suite acts as a man in the middle: it posts a list of calls to this service,
/// and each call names a URL on the suite to forward to. The suite then looks at the
/// headers that arrived at that URL, which is how a hop is measured — whether the
/// trace id survived, whether the span id is this hop's own, what happened to a
/// header that did not parse.
///
/// So this program is a hop and nothing else: read the context off the request, open
/// a span as its child, write that span's context onto every forwarded call, and
/// answer with what each call returned.
async fn main {
  let arguments = @env.args()
  let port = if arguments.length() > 1 {
    parse_port(arguments[1]) catch {
      _ => abort("the port is the first argument, e.g. 8080")
    }
  } else {
    8080
  }
  println("trace-context hop listening on http://127.0.0.1:\{port}")
  @mooncat.serve(hop, host="127.0.0.1", port~)
}

///|
/// The one tracer this process uses. It drops every finished span: the suite reads
/// the context that reaches the next hop, and a sink would only keep memory.
let tracer : @trace.Tracer = @trace.Tracer::new(
  rand=random_bytes,
  sink=@trace.discard,
  sampler=@trace.parent_based(root=@trace.always),
)

///|
/// One field of a JSON object, or `None` when the payload is not an object or has no
/// such field.
fn field(json : @json.Json, name : String) -> @json.Json? {
  match json {
    @json.Object(fields) => fields.get(name)
    _ => None
  }
}

///|
async fn hop(
  scope : @spec.Scope,
  receive : @spec.Receive,
  send : @spec.Send,
) -> Unit {
  match scope {
    @spec.Lifespan(_) => serve_lifespan(receive, send)
    @spec.Http(http) => {
      let body = read_body(receive)
      let payload = @json.parse(body[:], preserve_number_repr=true) catch {
        _ => @json.Json::array([])
      }
      let extracted = @propagate.extract(http.headers)
      let results : Array[@json.Json] = []
      for action in actions(payload) {
        let url = match field(action, "url") {
          Some(@json.String(url)) => url
          _ => continue
        }
        let headers = headers_of(action)
        // One span per call: three calls made on behalf of one request are three
        // outbound operations, and the next hop sees three different parents.
        let span = start_hop(extracted)
        let outgoing = match span {
          Some(span) =>
            @propagate.inject(headers, {
              context: Some(span.context()),
              baggage: extracted.baggage,
            })
          None => headers
        }
        results.push(forward(url, outgoing))
        match span {
          Some(span) => span.finish(at=0L)
          None => ()
        }
      }
      let answer = @json.Json::object(Map([("results", @json.Json::array(results))]))
      send(
        @spec.HttpResponseStart(
          status=200,
          headers=[("content-type", "application/json")],
          trailers=false,
        ),
      )
      send(
        @spec.HttpResponseBody(
          body=@utf8.encode(answer.stringify()),
          more_body=false,
        ),
      )
    }
    _ => ()
  }
}

///|
/// A hop for `extracted`: a child of the context the request carried, or the first
/// span of a new trace when the request carried none or carried one that does not
/// parse.
fn start_hop(extracted : @propagate.Extracted) -> @trace.Span? {
  let started = try {
    match extracted.context {
      Some(parent) =>
        Ok(tracer.start("forward", parent~, kind=@trace.Client, at=0L))
      None => Ok(tracer.start("forward", kind=@trace.Client, at=0L))
    }
  } catch {
    _ => Err(())
  }
  match started {
    Ok(span) => Some(span)
    Err(_) => None
  }
}

///|
/// The calls the suite asked for: a list, or a single call written on its own.
fn actions(payload : @json.Json) -> Array[@json.Json] {
  match payload {
    @json.Array(items) => items
    other => [other]
  }
}

///|
/// The headers a call asks this hop to send along, as name-value pairs.
fn headers_of(action : @json.Json) -> Array[(String, String)] {
  let headers : Array[(String, String)] = []
  match field(action, "headers") {
    Some(@json.Array(items)) =>
      for item in items {
        match item {
          @json.Array(pair) =>
            match pair {
              [@json.String(name), @json.String(value)] =>
                headers.push((name, value))
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  headers
}

///|
/// Forward one call and answer with what came back, in the shape the suite reads.
async fn forward(
  url : String,
  headers : Array[(String, String)],
) -> @json.Json {
  let outcome = try {
    Ok(@moonfetch.post(url[:], body=@moonfetch.Body::Text("[]"), headers~))
  } catch {
    error => Err("\{error}")
  }
  let fields : Map[String, @json.Json] = Map([])
  fields["url"] = @json.Json::string(url)
  match outcome {
    Ok(response) => {
      fields["status"] = @json.Json::number(response.status.to_double())
      let pairs : Array[@json.Json] = []
      for header in response.headers {
        pairs.push(
          @json.Json::array([
            @json.Json::string(header.0),
            @json.Json::string(header.1),
          ]),
        )
      }
      fields["headers"] = @json.Json::array(pairs)
      fields["body"] = @json.Json::string(response.text())
    }
    Err(reason) => {
      fields["exception"] = @json.Json::string(reason)
      fields["status"] = @json.Json::number(0.0)
      fields["headers"] = @json.Json::array([])
      fields["body"] = @json.Json::string("")
    }
  }
  @json.Json::object(fields)
}

///|
/// The request body, however many chunks it arrives in.
async fn read_body(receive : @spec.Receive) -> String {
  let bytes : Array[Byte] = []
  let mut more = true
  while more {
    match receive() {
      @spec.HttpRequest(body~, more_body~) => {
        for byte in body {
          bytes.push(byte)
        }
        more = more_body
      }
      _ => more = false
    }
  }
  @utf8.decode_lossy(Bytes::from_array(bytes)[:])
}

///|
/// The lifespan of a server that has nothing to start or stop: it still has to answer,
/// or the server waits on it.
async fn serve_lifespan(
  receive : @spec.Receive,
  send : @spec.Send,
) -> Unit {
  match receive() {
    @spec.LifespanStartup => send(@spec.LifespanStartupComplete)
    _ => ()
  }
  match receive() {
    @spec.LifespanShutdown => send(@spec.LifespanShutdownComplete)
    _ => ()
  }
}

///|
fn random_bytes(width : Int32) -> Bytes {
  @moonseed.bytes(width, @system.source) catch {
    _ => abort("the platform has no entropy source")
  }
}

///|
fn parse_port(text : String) -> Int32 raise {
  let mut value = 0
  for c in text {
    let digit = c.to_int() - 0x30
    if digit < 0 || digit > 9 {
      raise Failure::NotAPort(text)
    }
    value = value * 10 + digit
  }
  value
}

///|
pub(all) suberror Failure {
  NotAPort(String)
}

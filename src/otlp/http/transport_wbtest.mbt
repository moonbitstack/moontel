// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A request with a body small enough to check by eye.
fn packed(headers : Array[(String, String)]) -> @otlp.Request {
  {
    url: "http://collector.test:4318/v1/traces",
    headers,
    body: "{\"resourceSpans\":[]}",
  }
}

///|
test "a plain body is the encoder's text and the caller's headers" {
  let (body, headers) = payload(packed([("x-api-key", "secret")]), Plain)
  assert_eq(body, @moonfetch.Body::Text("{\"resourceSpans\":[]}"))
  assert_eq(headers, [("x-api-key", "secret")])
}

///|
test "a gzipped body says so, and comes back as it went in" {
  let (body, headers) = payload(packed([("x-api-key", "secret")]), Gzip)
  assert_eq(headers[0], ("x-api-key", "secret"))
  assert_eq(headers[1], ("Content-Encoding", "gzip"))
  match body {
    @moonfetch.Body::Bytes(bytes) => {
      // The proof that the header is not a lie: what the server will do to it.
      let back = @gzip.gunzip(bytes[:]) catch { _ => b"" }
      assert_eq(back, @utf8.encode("{\"resourceSpans\":[]}"))
    }
    other => fail("expected bytes, got \{other.to_repr()}")
  }
}

///|
test "a content-encoding the caller wrote is replaced, not repeated" {
  let (_, headers) = payload(
    packed([("Content-Encoding", "identity"), ("x-api-key", "secret")]),
    Gzip,
  )
  let encodings = headers.filter(header => {
    header.0.to_lower() == "content-encoding"
  })
  assert_eq(encodings.length(), 1)
  assert_eq(encodings[0], ("Content-Encoding", "gzip"))
}

///|
test "the same body compresses to the same bytes" {
  // A gzip header carries a modification time; this one is zero, so two requests
  // with one body are two identical requests.
  let first = payload(packed([]), Gzip).0
  let second = payload(packed([]), Gzip).0
  assert_eq(first, second)
}

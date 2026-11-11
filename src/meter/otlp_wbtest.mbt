// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A transport that keeps the requests it was handed and answers success.
struct Capture {
  requests : Ref[Array[@otlp.Request]]
}

///|
fn Capture::new() -> Capture {
  { requests: Ref([]), }
}

///|
impl @otlp.Transport for Capture with fn send(self, request) {
  self.requests.val.push(request)
  { status: 200, headers: [], body: b"", }
}

///|
async test "the meter's points leave through the same exporter as spans and logs" {
  let capture = Capture::new()
  let exporter = @otlp.MetricsExporter::new(
    transport=capture,
    endpoint="http://collector.test:4318",
    resource=@otlp.Resource::of_service("orders"),
    now=() => 0L,
    rand=_ => b"\x00\x00\x00\x00",
  )
  let provider = MeterProvider::new(sink=exporter, now=() => 0L, start=1L)
  let meter = provider.meter(name="moontel-test")
  let counter = meter.counter("orders.placed", unit="{order}")
  let duration = meter.histogram("gen_ai.client.operation.duration", unit="s")
  counter.add(2.0, at=20L)
  duration.record(6.0, at=21L)
  provider.emit(at=30L) |> ignore
  assert_eq(exporter.waiting(), 2)
  let report = exporter.flush()
  assert_eq(report.delivered, 2)
  assert_eq(report.dropped, 0)
  let requests = capture.requests.val
  assert_eq(requests.length(), 1)
  assert_eq(requests[0].url, "http://collector.test:4318/v1/metrics")
  let body = @utf8.decode_lossy(requests[0].body[:])
  assert_true(body.contains("\"service.name\""))
  assert_true(body.contains("\"stringValue\":\"orders\""))
  assert_true(body.contains("\"name\":\"orders.placed\""))
  assert_true(body.contains("\"unit\":\"{order}\""))
  assert_true(body.contains("\"asDouble\":2"))
  assert_true(body.contains("\"name\":\"gen_ai.client.operation.duration\""))
  assert_true(body.contains("\"unit\":\"s\""))
  assert_true(
    body.contains(
      "\"explicitBounds\":[0,5,10,25,50,75,100,250,500,750,1000,2500,5000,7500,10000]",
    ),
  )
}

///|
async test "a metric recorder and an exporter see the same metric shape" {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(sink=recorder, now=() => 0L, start=1L)
  let counter = provider.meter(name="moontel-test").counter("hits")
  counter.inc(at=20L)
  provider.emit(at=30L) |> ignore
  assert_eq(recorder.len(), 1)
  let body = @otlp.encode_metrics(recorder.metrics())
  assert_true(body.contains("\"name\":\"hits\""))
  assert_true(body.contains("\"asDouble\":1"))
}

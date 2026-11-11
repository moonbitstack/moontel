// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn recording_setup() -> (MeterProvider, Meter, @otlp.MetricRecorder) {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(sink=recorder, now=() => 0L, start=1L)
  (provider, provider.meter(name="moontel-test", version="1.0"), recorder)
}

///|
test "emit hands one metric per instrument to the shared sink" {
  let (provider, meter, recorder) = recording_setup()
  let _ = meter.counter("requests", unit="{request}")
  let _ = meter.up_down_counter("queue.depth", unit="{job}")
  let _ = meter.histogram("gen_ai.client.operation.duration", unit="s")
  let _ = meter.gauge("temperature", unit="Cel")
  let metrics = provider.emit(at=100L)
  assert_eq(metrics.length(), 4)
  assert_eq(recorder.len(), 4)
  assert_eq(recorder.metrics()[0].name, metrics[0].name)
  assert_eq(recorder.take().length(), 4)
  assert_eq(recorder.len(), 0)
  assert_eq(metrics[0].name, "requests")
  assert_eq(metrics[1].name, "queue.depth")
  assert_eq(metrics[2].name, "gen_ai.client.operation.duration")
  assert_eq(metrics[3].name, "temperature")
  assert_eq(meter.scope().name, "moontel-test")
  assert_eq(meter.scope().version, Some("1.0"))
  assert_eq(provider.temporality(), @otlp.Cumulative)
  assert_eq(provider.limits(), meter_limits)
}

///|
test "a cumulative collection can be read twice without changing what it says" {
  let (provider, meter, _) = recording_setup()
  let counter = meter.counter("requests")
  counter.add(3.0, at=20L)
  let first = provider.collect(at=30L)
  let second = provider.collect(at=40L)
  assert_eq(first[0].points[0].point, @otlp.AsDouble(3.0))
  assert_eq(second[0].points[0].point, @otlp.AsDouble(3.0))
  assert_eq(second[0].points[0].time, 40L)
  assert_eq(second[0].points[0].start, Some(1L))
}

///|
test "a delta emit clears the accumulations so one measurement is sent once" {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(
    sink=recorder,
    now=() => 0L,
    start=1L,
    temporality=@otlp.Delta,
  )
  let meter = provider.meter(name="moontel-test")
  let counter = meter.counter("requests")
  counter.add(3.0, at=20L)
  let first = provider.emit(at=30L)
  assert_eq(first[0].points[0].point, @otlp.AsDouble(3.0))
  assert_eq(first[0].points[0].start, Some(20L))
  assert_eq(first[0].kind, @otlp.Sum(temporality=@otlp.Delta, monotonic=true))
  let second = provider.emit(at=40L)
  assert_eq(second[0].points.length(), 0)
  counter.add(2.0, at=41L)
  let third = provider.emit(at=50L)
  assert_eq(third[0].points.length(), 1)
  assert_eq(third[0].points[0].point, @otlp.AsDouble(2.0))
  assert_eq(recorder.len(), 3)
}

///|
test "the OTLP/JSON body keeps the dotted name, the unit, the attributes and every bucket" {
  let (provider, meter, _) = recording_setup()
  let duration = meter.histogram(
    @semconv.gen_ai_client_operation_duration,
    description="GenAI operation duration.",
    unit="s",
  )
  duration.record(
    6.0,
    at=20L,
    attributes=gen_ai_client_attributes(
      provider="acme",
      operation="chat",
      request_model="model-a",
    ),
  )
  let body = @otlp.encode_metrics(provider.collect(at=30L))
  assert_true(body.contains("\"name\":\"gen_ai.client.operation.duration\""))
  assert_true(body.contains("\"description\":\"GenAI operation duration.\""))
  assert_true(body.contains("\"unit\":\"s\""))
  assert_true(body.contains("\"key\":\"gen_ai.provider.name\""))
  assert_true(body.contains("\"key\":\"gen_ai.request.model\""))
  assert_true(body.contains("\"stringValue\":\"model-a\""))
  assert_true(body.contains("\"aggregationTemporality\":2"))
  assert_true(
    body.contains(
      "\"explicitBounds\":[0,5,10,25,50,75,100,250,500,750,1000,2500,5000,7500,10000]",
    ),
  )
  assert_true(
    body.contains(
      "\"bucketCounts\":[\"0\",\"0\",\"1\",\"0\",\"0\",\"0\",\"0\",\"0\",\"0\",\"0\",\"0\",\"0\",\"0\",\"0\",\"0\",\"0\"]",
    ),
  )
  assert_true(body.contains("\"count\":\"1\""))
  assert_true(body.contains("\"sum\":6"))
  assert_true(body.contains("\"min\":6"))
  assert_true(body.contains("\"max\":6"))
}

///|
test "a name too long for the specification is refused with its limit" {
  let (_, meter, _) = recording_setup()
  let builder = StringBuilder()
  for _ in 0..<(instrument_name_limit + 1) {
    builder.write_char('a')
  }
  let long = builder.to_string()
  let refused = try {
    meter.counter(long) |> ignore
    false
  } catch {
    Refused::LongName(got~, limit~, ..) =>
      got == instrument_name_limit + 1 && limit == instrument_name_limit
    _ => false
  }
  assert_true(refused)
}

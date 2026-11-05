// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Encode metrics as an OTLP `ExportMetricsServiceRequest` in the binary protobuf
/// encoding: the same request as the JSON encoder, for
/// `/v1/metrics` with `Content-Type: application/x-protobuf`.
///
/// A bucket count and a bound are packed repeated fields, which is what the schema
/// asks for; the counts are the per-bucket ones the point already carries, not a
/// running total.
pub fn encode_metrics_protobuf(
  metrics : Array[Metric],
  resource~ : Resource = unknown_service,
  scope~ : Scope = moonbit_scope,
) -> Bytes {
  let request = ProtoWriter::new()
  let resource_metrics = ProtoWriter::new()
  resource_metrics.message(1, resource_message(resource))
  let scope_metrics = ProtoWriter::new()
  scope_metrics.message(1, scope_message(scope))
  for metric in metrics {
    scope_metrics.message(2, metric_message(metric))
  }
  resource_metrics.message(2, scope_metrics)
  request.message(1, resource_metrics)
  request.finish()
}

///|
fn metric_message(metric : Metric) -> ProtoWriter {
  let w = ProtoWriter::new()
  w.string(1, metric.name)
  if metric.description != "" {
    w.string(2, metric.description)
  }
  if metric.unit != "" {
    w.string(3, metric.unit)
  }
  match metric.kind {
    Gauge => {
      let body = ProtoWriter::new()
      write_point_messages(body, 1, metric.points)
      w.message(5, body)
    }
    Sum(temporality~, monotonic~) => {
      let body = ProtoWriter::new()
      write_point_messages(body, 1, metric.points)
      body.enum_code(2, temporality_code(temporality))
      body.bool(3, monotonic)
      w.message(7, body)
    }
    Histogram(temporality~) => {
      let body = ProtoWriter::new()
      write_point_messages(body, 1, metric.points)
      body.enum_code(2, temporality_code(temporality))
      w.message(9, body)
    }
    Summary => {
      let body = ProtoWriter::new()
      write_point_messages(body, 1, metric.points)
      w.message(11, body)
    }
  }
  w
}

///|
fn write_point_messages(
  w : ProtoWriter,
  field : Int32,
  points : Array[DataPoint],
) -> Unit {
  for point in points {
    w.message(field, data_point_message(point))
  }
}

///|
fn data_point_message(data : DataPoint) -> ProtoWriter {
  let w = ProtoWriter::new()
  match data.start {
    Some(start) => w.fixed64(2, start.reinterpret_as_uint64())
    None => ()
  }
  w.fixed64(3, data.time.reinterpret_as_uint64())
  match data.point {
    AsDouble(value) => w.double(4, value)
    AsInt(value) => w.int64(6, value)
    Buckets(bounds~, counts~, sum~, count~, min~, max~) => {
      w.fixed64(4, count.reinterpret_as_uint64())
      w.double(5, sum)
      w.packed_fixed64(6, counts.map(c => c.reinterpret_as_uint64()))
      w.packed_doubles(7, bounds)
      write_exemplars(w, 8, data.exemplars)
      if data.flags != 0 {
        w.fixed32(10, data.flags.reinterpret_as_uint())
      }
      match min {
        Some(value) => w.double(11, value)
        None => ()
      }
      match max {
        Some(value) => w.double(12, value)
        None => ()
      }
      write_key_values(w, 9, data.attributes)
      return w
    }
    Quantiles(quantiles~, sum~, count~) => {
      w.fixed64(4, count.reinterpret_as_uint64())
      w.double(5, sum)
      for quantile in quantiles {
        let value = ProtoWriter::new()
        value.double(1, quantile.0)
        value.double(2, quantile.1)
        w.message(6, value)
      }
      if data.flags != 0 {
        w.fixed32(8, data.flags.reinterpret_as_uint())
      }
      write_key_values(w, 7, data.attributes)
      return w
    }
  }
  write_exemplars(w, 5, data.exemplars)
  if data.flags != 0 {
    w.fixed32(8, data.flags.reinterpret_as_uint())
  }
  write_key_values(w, 7, data.attributes)
  w
}

///|
fn write_exemplars(
  w : ProtoWriter,
  field : Int32,
  exemplars : Array[Exemplar],
) -> Unit {
  for exemplar in exemplars {
    let e = ProtoWriter::new()
    e.fixed64(2, exemplar.time.reinterpret_as_uint64())
    e.double(3, exemplar.value)
    match exemplar.span_id {
      Some(span_id) => e.bytes(4, span_id[:])
      None => ()
    }
    match exemplar.trace_id {
      Some(trace_id) => e.bytes(5, trace_id[:])
      None => ()
    }
    write_key_values(e, 7, exemplar.attributes)
    w.message(field, e)
  }
}

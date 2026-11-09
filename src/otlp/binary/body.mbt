// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The binary encoding of the three signals: the OTLP messages, filled in from what
/// the library collected and written by a schema encoder.
///
/// The messages in this package are generated from the protocol's own schema
/// (`scripts/otlp-schema`), so the field numbers and the wire types are the ones the
/// protocol publishes rather than ones copied into a writer by hand.
pub struct Protobuf {}

///|
/// The protobuf encoding, ready to hand to an exporter.
pub let protobuf : &@otlp.Encoding = Protobuf::{ }

///|
impl @otlp.Encoding for Protobuf with fn format(_self) {
  @otlp.BodyFormat::Protobuf
}

///|
impl @otlp.Encoding for Protobuf with fn traces(_self, spans, resource, scope) {
  encode_traces(spans, resource~, scope~)
}

///|
impl @otlp.Encoding for Protobuf with fn logs(_self, records, resource, scope) {
  encode_logs(records, resource~, scope~)
}

///|
impl @otlp.Encoding for Protobuf with fn metrics(
  _self,
  metrics,
  resource,
  scope,
) {
  encode_metrics(metrics, resource~, scope~)
}

///|
impl @otlp.Encoding for Protobuf with fn rejected(_self, body) {
  rejected_in_reply(body)
}

///|
/// One request body, as the schema's writer produces it.
///
/// A message built here has no required field and no cycle, so the writer has
/// nothing to refuse. A refusal would mean this package and the schema disagree,
/// and an empty body sent as if it were the records would hide that: it stops
/// instead.
fn[M : @reflect.Message] encoded(message : M) -> Bytes {
  @proto.encode(message) catch {
    refused =>
      abort("moontel built a message the OTLP schema refused: \{refused}")
  }
}

///|
/// Fill a repeated field with these values.
///
/// The schema's view of a repeated field writes into the array the message holds, so
/// the field has to be the one passed in: a view built over a copy would be a
/// message that encodes to nothing.
fn[T] fill(
  field : Array[T],
  values : Array[T],
  element : @reflect.Element[T],
) -> Unit {
  @reflect.assign_list(field, @reflect.list_view(values, element), element)
}

///|
/// A repeated message field, the way the schema walks it: how to build an element,
/// and how to merge into one.
fn[T : @reflect.Message] messages(fresh : () -> T) -> @reflect.Element[T] {
  @reflect.message_element(
    value => @reflect.Message(value as &@reflect.Message),
    fresh,
    (value, into) => @proto.merge(value, into),
  )
}

///|
/// One `/v1/traces` request body: every span under the resource and the scope that
/// produced it, which is the nesting the protocol defines.
pub fn encode_traces(
  spans : Array[@trace.SpanData],
  resource~ : @otlp.Resource = @otlp.unknown_service,
  scope~ : @otlp.Scope = @otlp.moonbit_scope,
) -> Bytes {
  let scope_spans = ScopeSpans::new()
  scope_spans.scope = Some(scope_message(scope))
  fill(scope_spans.spans, spans.map(span_message), messages(() => Span::new()))
  let resource_spans = ResourceSpans::new()
  resource_spans.resource = Some(resource_message(resource))
  fill(
    resource_spans.scope_spans,
    [scope_spans],
    messages(() => ScopeSpans::new()),
  )
  let request = ExportTraceServiceRequest::new()
  fill(
    request.resource_spans,
    [resource_spans],
    messages(() => ResourceSpans::new()),
  )
  encoded(request)
}

///|
/// One `/v1/logs` request body.
///
/// Records are grouped by the scope they were written under, which is what the
/// message nests on; the order of first appearance is kept, so a reader of the
/// payload sees the scopes in the order the program used them.
pub fn encode_logs(
  records : Array[@log.LogRecord],
  resource~ : @otlp.Resource = @otlp.unknown_service,
  scope~ : @otlp.Scope = @otlp.moonbit_scope,
) -> Bytes {
  let names : Array[String] = []
  for record in records {
    if !names.contains(record.scope) {
      names.push(record.scope)
    }
  }
  let scope_logs : Array[ScopeLogs] = []
  for name in names {
    // A record written without a scope of its own belongs to the exporter's, the
    // same way the JSON encoder decides it.
    let one = ScopeLogs::new()
    one.scope = Some(
      scope_message({
        ..scope,
        name: if name == "" {
          scope.name
        } else {
          name
        },
      }),
    )
    fill(
      one.log_records,
      records.filter(record => record.scope == name).map(log_record_message),
      messages(() => LogRecord::new()),
    )
    scope_logs.push(one)
  }
  let resource_logs = ResourceLogs::new()
  resource_logs.resource = Some(resource_message(resource))
  fill(resource_logs.scope_logs, scope_logs, messages(() => ScopeLogs::new()))
  let request = ExportLogsServiceRequest::new()
  fill(
    request.resource_logs,
    [resource_logs],
    messages(() => ResourceLogs::new()),
  )
  encoded(request)
}

///|
/// One `/v1/metrics` request body.
pub fn encode_metrics(
  metrics : Array[@otlp.Metric],
  resource~ : @otlp.Resource = @otlp.unknown_service,
  scope~ : @otlp.Scope = @otlp.moonbit_scope,
) -> Bytes {
  let scope_metrics = ScopeMetrics::new()
  scope_metrics.scope = Some(scope_message(scope))
  fill(
    scope_metrics.metrics,
    metrics.map(metric_message),
    messages(() => Metric::new()),
  )
  let resource_metrics = ResourceMetrics::new()
  resource_metrics.resource = Some(resource_message(resource))
  fill(
    resource_metrics.scope_metrics,
    [scope_metrics],
    messages(() => ScopeMetrics::new()),
  )
  let request = ExportMetricsServiceRequest::new()
  fill(
    request.resource_metrics,
    [resource_metrics],
    messages(() => ResourceMetrics::new()),
  )
  encoded(request)
}

///|
/// The `Resource` message: the attribute set that says what produced this
/// telemetry.
fn resource_message(resource : @otlp.Resource) -> Resource {
  let message = Resource::new()
  fill(
    message.attributes,
    key_values(resource.attributes),
    messages(() => KeyValue::new()),
  )
  message
}

///|
/// The `InstrumentationScope` message: which library in the program produced this.
fn scope_message(scope : @otlp.Scope) -> InstrumentationScope {
  let message = InstrumentationScope::new()
  message.set_name(scope.name)
  match scope.version {
    Some(version) => message.set_version(version)
    None => ()
  }
  fill(
    message.attributes,
    key_values(scope.attributes),
    messages(() => KeyValue::new()),
  )
  message
}

///|
/// Repeated `KeyValue`: a name, and a value tagged with its type.
fn key_values(attributes : Array[(String, @trace.Value)]) -> Array[KeyValue] {
  attributes.map(pair => {
    let message = KeyValue::new()
    message.set_key(pair.0)
    message.value = Some(any_value(pair.1))
    message
  })
}

///|
/// One attribute value as the `AnyValue` oneof: the field that carries it is the
/// type, so a reader cannot mistake `200` for text.
///
/// An array keeps the type of its elements, because an array attribute is
/// homogeneous — which is why the value type has one array variant per element
/// type rather than one array of values.
fn any_value(value : @trace.Value) -> AnyValue {
  let message = AnyValue::new()
  message.value = match value {
    @trace.Str(text) => AnyValue_Value::String_value(text)
    @trace.Bool(flag) => AnyValue_Value::Bool_value(flag)
    @trace.Int(number) => AnyValue_Value::Int_value(number)
    @trace.Double(number) => AnyValue_Value::Double_value(number)
    @trace.Bools(values) =>
      AnyValue_Value::Array_value(
        array_value(values.map(flag => @trace.Bool(flag))),
      )
    @trace.Ints(values) =>
      AnyValue_Value::Array_value(
        array_value(values.map(number => @trace.Int(number))),
      )
    @trace.Doubles(values) =>
      AnyValue_Value::Array_value(
        array_value(values.map(number => @trace.Double(number))),
      )
    @trace.Strs(values) =>
      AnyValue_Value::Array_value(
        array_value(values.map(text => @trace.Str(text))),
      )
  }
  message
}

///|
/// The `ArrayValue` of an attribute whose elements are all of one type.
fn array_value(values : Array[@trace.Value]) -> ArrayValue {
  let message = ArrayValue::new()
  fill(message.values, values.map(any_value), messages(() => AnyValue::new()))
  message
}

///|
/// One `Span`, with the ids as the bytes they are rather than the hex of them.
fn span_message(span : @trace.SpanData) -> Span {
  let message = Span::new()
  message.set_trace_id(span.context.trace_id)
  message.set_span_id(span.context.span_id)
  match span.parent {
    Some(parent) => message.set_parent_span_id(parent)
    None => ()
  }
  message.set_name(span.name)
  message.set_kind(@otlp.kind_code(span.kind))
  message.set_start_time_unix_nano(span.start.reinterpret_as_uint64())
  message.set_end_time_unix_nano(span.end.reinterpret_as_uint64())
  fill(
    message.attributes,
    key_values(span.attributes),
    messages(() => KeyValue::new()),
  )
  if span.dropped.attributes > 0 {
    message.set_dropped_attributes_count(
      span.dropped.attributes.reinterpret_as_uint(),
    )
  }
  fill(
    message.events,
    span.events.map(event_message),
    messages(() => Span_Event::new()),
  )
  if span.dropped.events > 0 {
    message.set_dropped_events_count(span.dropped.events.reinterpret_as_uint())
  }
  fill(
    message.links,
    span.links.map(link_message),
    messages(() => Span_Link::new()),
  )
  if span.dropped.links > 0 {
    message.set_dropped_links_count(span.dropped.links.reinterpret_as_uint())
  }
  match span.status {
    // An unset status is the absent field: the protocol's default is what the
    // reader assumes when no status is there.
    @trace.Unset => ()
    @trace.Ok => {
      let status = Status::new()
      status.set_code(1)
      message.status = Some(status)
    }
    @trace.Error(reason) => {
      let status = Status::new()
      status.set_code(2)
      if reason != "" {
        status.set_message_field(reason)
      }
      message.status = Some(status)
    }
  }
  if span.context.flags != b'\x00' {
    message.set_flags(span.context.flags.to_int().reinterpret_as_uint())
  }
  message
}

///|
fn event_message(event : @trace.Event) -> Span_Event {
  let message = Span_Event::new()
  message.set_time_unix_nano(event.at.reinterpret_as_uint64())
  message.set_name(event.name)
  fill(
    message.attributes,
    key_values(event.attributes),
    messages(() => KeyValue::new()),
  )
  message
}

///|
fn link_message(link : @trace.Link) -> Span_Link {
  let message = Span_Link::new()
  message.set_trace_id(link.context.trace_id)
  message.set_span_id(link.context.span_id)
  fill(
    message.attributes,
    key_values(link.attributes),
    messages(() => KeyValue::new()),
  )
  message
}

///|
/// One `LogRecord`, with the severity as the number the protocol gives it.
fn log_record_message(record : @log.LogRecord) -> LogRecord {
  let message = LogRecord::new()
  match record.time {
    Some(time) => message.set_time_unix_nano(time.reinterpret_as_uint64())
    None => ()
  }
  message.set_severity_number(record.severity.number())
  message.set_severity_text(record.severity_text())
  message.body = Some(any_value(record.body))
  fill(
    message.attributes,
    key_values(record.attributes),
    messages(() => KeyValue::new()),
  )
  if record.dropped > 0 {
    message.set_dropped_attributes_count(record.dropped.reinterpret_as_uint())
  }
  match (record.trace_id, record.span_id) {
    (Some(trace_id), Some(span_id)) => {
      message.set_trace_id(trace_id)
      message.set_span_id(span_id)
      if record.flags != b'\x00' {
        message.set_flags(record.flags.to_int().reinterpret_as_uint())
      }
    }
    _ => ()
  }
  message.set_observed_time_unix_nano(record.observed.reinterpret_as_uint64())
  match record.event_name {
    Some(name) => if name != "" { message.set_event_name(name) }
    None => ()
  }
  message
}

///|
/// One `Metric`, with the data oneof the kind it carries.
fn metric_message(metric : @otlp.Metric) -> Metric {
  let message = Metric::new()
  message.set_name(metric.name)
  if metric.description != "" {
    message.set_description(metric.description)
  }
  if metric.unit != "" {
    message.set_unit(metric.unit)
  }
  message.data = match metric.kind {
    @otlp.Gauge => {
      let gauge = Gauge::new()
      fill(
        gauge.data_points,
        metric.points.map(number_point),
        messages(() => NumberDataPoint::new()),
      )
      Metric_Data::Gauge(gauge)
    }
    @otlp.Sum(temporality~, monotonic~) => {
      let sum = Sum::new()
      fill(
        sum.data_points,
        metric.points.map(number_point),
        messages(() => NumberDataPoint::new()),
      )
      sum.set_aggregation_temporality(@otlp.temporality_code(temporality))
      sum.set_is_monotonic(monotonic)
      Metric_Data::Sum(sum)
    }
    @otlp.Histogram(temporality~) => {
      let histogram = Histogram::new()
      fill(
        histogram.data_points,
        metric.points.map(histogram_point),
        messages(() => HistogramDataPoint::new()),
      )
      histogram.set_aggregation_temporality(@otlp.temporality_code(temporality))
      Metric_Data::Histogram(histogram)
    }
    @otlp.Summary => {
      let summary = Summary::new()
      fill(
        summary.data_points,
        metric.points.map(summary_point),
        messages(() => SummaryDataPoint::new()),
      )
      Metric_Data::Summary(summary)
    }
  }
  message
}

///|
/// A point of a gauge or a sum: a number, and which number it is.
fn number_point(data : @otlp.DataPoint) -> NumberDataPoint {
  let message = NumberDataPoint::new()
  match data.start {
    Some(start) =>
      message.set_start_time_unix_nano(start.reinterpret_as_uint64())
    None => ()
  }
  message.set_time_unix_nano(data.time.reinterpret_as_uint64())
  message.value = match data.point {
    @otlp.AsDouble(number) => NumberDataPoint_Value::As_double(number)
    @otlp.AsInt(number) => NumberDataPoint_Value::As_int(number)
    _ => abort("a gauge or sum point carries a number")
  }
  fill(
    message.exemplars,
    exemplars(data.exemplars),
    messages(() => Exemplar::new()),
  )
  if data.flags != 0 {
    message.set_flags(data.flags.reinterpret_as_uint())
  }
  fill(
    message.attributes,
    key_values(data.attributes),
    messages(() => KeyValue::new()),
  )
  message
}

///|
/// A point of a histogram: the bounds, one more count than there are bounds, and the
/// aggregation the buckets are made of.
fn histogram_point(data : @otlp.DataPoint) -> HistogramDataPoint {
  let message = HistogramDataPoint::new()
  match data.start {
    Some(start) =>
      message.set_start_time_unix_nano(start.reinterpret_as_uint64())
    None => ()
  }
  message.set_time_unix_nano(data.time.reinterpret_as_uint64())
  match data.point {
    @otlp.Buckets(bounds~, counts~, sum~, count~, min~, max~) => {
      message.set_count(count.reinterpret_as_uint64())
      message.set_sum(sum)
      fill(
        message.bucket_counts,
        counts.map(bucket => bucket.reinterpret_as_uint64()),
        @reflect.scalar_element(
          value => @reflect.Uint64(value),
          value => value.uint(),
          () => 0UL,
        ),
      )
      fill(
        message.explicit_bounds,
        bounds,
        @reflect.scalar_element(
          value => @reflect.Double(value),
          value => value.float(),
          () => 0.0,
        ),
      )
      match min {
        Some(value) => message.set_min(value)
        None => ()
      }
      match max {
        Some(value) => message.set_max(value)
        None => ()
      }
    }
    _ => abort("a histogram point carries buckets")
  }
  fill(
    message.exemplars,
    exemplars(data.exemplars),
    messages(() => Exemplar::new()),
  )
  if data.flags != 0 {
    message.set_flags(data.flags.reinterpret_as_uint())
  }
  fill(
    message.attributes,
    key_values(data.attributes),
    messages(() => KeyValue::new()),
  )
  message
}

///|
/// A point of a summary: a count, a sum and the quantiles the producer kept.
fn summary_point(data : @otlp.DataPoint) -> SummaryDataPoint {
  let message = SummaryDataPoint::new()
  match data.start {
    Some(start) =>
      message.set_start_time_unix_nano(start.reinterpret_as_uint64())
    None => ()
  }
  message.set_time_unix_nano(data.time.reinterpret_as_uint64())
  match data.point {
    @otlp.Quantiles(quantiles~, sum~, count~) => {
      message.set_count(count.reinterpret_as_uint64())
      message.set_sum(sum)
      fill(
        message.quantile_values,
        quantiles.map(pair => {
          let value = SummaryDataPoint_ValueAtQuantile::new()
          value.set_quantile(pair.0)
          value.set_value(pair.1)
          value
        }),
        messages(() => SummaryDataPoint_ValueAtQuantile::new()),
      )
    }
    _ => abort("a summary point carries quantiles")
  }
  if data.flags != 0 {
    message.set_flags(data.flags.reinterpret_as_uint())
  }
  fill(
    message.attributes,
    key_values(data.attributes),
    messages(() => KeyValue::new()),
  )
  message
}

///|
/// The exemplars of one point: the sample of what the number was made of.
fn exemplars(values : Array[@otlp.Exemplar]) -> Array[Exemplar] {
  values.map(value => {
    let message = Exemplar::new()
    message.set_time_unix_nano(value.time.reinterpret_as_uint64())
    message.value = Exemplar_Value::As_double(value.value)
    match value.span_id {
      Some(span_id) => message.set_span_id(span_id)
      None => ()
    }
    match value.trace_id {
      Some(trace_id) => message.set_trace_id(trace_id)
      None => ()
    }
    fill(
      message.filtered_attributes,
      key_values(value.attributes),
      messages(() => KeyValue::new()),
    )
    message
  })
}

///|
/// How many records the server said it refused, read out of a binary protobuf reply.
///
/// The three success responses are the same shape — a `partial_success` field, and
/// inside it the count for that signal at number 1 — so one reader serves all three.
/// A body that is not protobuf, or carries no `partial_success`, answers `None`:
/// "said nothing" and "refused none" are different things, and only the second is
/// good news.
fn rejected_in_reply(body : Bytes) -> Int32? {
  let reply = ExportTraceServiceResponse::new()
  @proto.decode(body, reply) catch {
    _ => return None
  }
  match reply.partial_success {
    // The count has no presence of its own, so inside a `partial_success` a count
    // left out is zero. It is a 64-bit field, and a count past what an `Int32`
    // holds is not one this side can report: it is clamped rather than wrapped.
    Some(success) => {
      let count = success.rejected_spans
      Some(if count > 2147483647L { 2147483647 } else { count.to_int() })
    }
    None => None
  }
}

///|
/// The schema's messages, registered by name when the module loads.
///
/// A codec resolves a field that names a message in another file through the
/// registry, and the messages this package writes are the protocol's: every one of
/// them goes in, so a body written here can be read back here.
fn register_types() -> Unit {
  register_common_types()
  register_resource_types()
  register_trace_types()
  register_logs_types()
  register_metrics_types()
  register_trace_service_types()
  register_logs_service_types()
  register_metrics_service_types()
}

///|
fn init {
  register_types()
}

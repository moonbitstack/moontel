#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
"""Run one fixed scenario through the OpenTelemetry Python SDK and print what it
produced, as JSON.

The scenario is the one `src/trace/crosscheck_test.mbt` replays: the same ids, the
same timestamps, the same attributes, the same events, and the same headers
injected at the end. Whatever this prints is the reference the MoonBit library is
held to, so the ids and the clock are pinned rather than random.

    pip install opentelemetry-sdk==1.45.0
    python3 scripts/otel_python_trace_dump.py > scripts/trace_crosscheck_expected.json

CI does not run this: it only replays the recorded JSON.

64-bit integers are written as decimal strings. A nanosecond timestamp is above
2^53, where a JSON number no longer round-trips through a double, and a record that
lost the last digits of every timestamp would be a record that cannot catch a
mistake in them.
"""

import json
import sys

from opentelemetry import baggage, trace
from opentelemetry.baggage.propagation import W3CBaggagePropagator
from opentelemetry.context import attach, detach
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor, SpanExporter
from opentelemetry.sdk.trace.id_generator import IdGenerator
from opentelemetry.sdk.trace.sampling import ALWAYS_ON, TraceIdRatioBased
from opentelemetry.trace import SpanKind, Status, StatusCode
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

# One fixed trace, one fixed span id per span, in the order the SDK asks for them.
TRACE_ID = 0x4BF92F3577B34DA6A3CE929D0E0E4736
SPAN_IDS = [0x00F067AA0BA902B7, 0x00F067AA0BA902B8, 0x00F067AA0BA902B9, 0x00F067AA0BA902BA]

START = 1_700_000_000_000_000_000
EVENT_AT = 1_700_000_000_100_000_000
CHILD_START = 1_700_000_000_200_000_000
CHILD_END = 1_700_000_000_300_000_000
END = 1_700_000_000_900_000_000

KIND_NAMES = {
    SpanKind.INTERNAL: "Internal",
    SpanKind.SERVER: "Server",
    SpanKind.CLIENT: "Client",
    SpanKind.PRODUCER: "Producer",
    SpanKind.CONSUMER: "Consumer",
}

STATUS_NAMES = {
    StatusCode.UNSET: "Unset",
    StatusCode.OK: "Ok",
    StatusCode.ERROR: "Error",
}


class FixedIds(IdGenerator):
    def __init__(self):
        self.span_ids = list(SPAN_IDS)

    def generate_trace_id(self):
        return TRACE_ID

    def generate_span_id(self):
        return self.span_ids.pop(0)


class Collect(SpanExporter):
    def __init__(self):
        self.spans = []

    def export(self, spans):
        self.spans.extend(spans)
        return True


def value_of(attribute_value):
    """An attribute as the JSON shape the MoonBit side compares against."""
    if isinstance(attribute_value, bool):
        return {"type": "bool", "value": attribute_value}
    if isinstance(attribute_value, int):
        return {"type": "int", "value": str(attribute_value)}
    if isinstance(attribute_value, float):
        return {"type": "double", "value": attribute_value}
    if isinstance(attribute_value, str):
        return {"type": "string", "value": attribute_value}
    if isinstance(attribute_value, (list, tuple)):
        kinds = {value_of(item)["type"] for item in attribute_value}
        if len(kinds) != 1:
            raise SystemExit(f"mixed attribute array: {attribute_value!r}")
        kind = kinds.pop()
        name = {"bool": "bools", "int": "ints", "double": "doubles", "string": "strings"}[kind]
        return {"type": name, "value": [value_of(item)["value"] for item in attribute_value]}
    raise SystemExit(f"attribute type this dump does not cover: {type(attribute_value)}")


def span_json(span):
    status = span.status
    return {
        "name": span.name,
        "kind": KIND_NAMES[span.kind],
        "trace_id": format(span.context.trace_id, "032x"),
        "span_id": format(span.context.span_id, "016x"),
        "parent_span_id": format(span.parent.span_id, "016x") if span.parent else None,
        "start": str(span.start_time),
        "end": str(span.end_time),
        "attributes": [[key, value_of(value)] for key, value in span.attributes.items()],
        "events": [
            {
                "name": event.name,
                "at": str(event.timestamp),
                "attributes": [[key, value_of(value)] for key, value in event.attributes.items()],
            }
            for event in span.events
        ],
        "status": {
            "code": STATUS_NAMES[status.status_code],
            "description": status.description or "",
        },
    }


def scenario():
    exporter = Collect()
    provider = TracerProvider(sampler=ALWAYS_ON, id_generator=FixedIds())
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    tracer = provider.get_tracer("crosscheck")

    root = tracer.start_span(
        "checkout",
        kind=SpanKind.SERVER,
        start_time=START,
        attributes={
            "order.id": "A-1024",
            "order.total": 42.5,
            "order.items": 3,
            "order.paid": True,
            "order.tags": ["new", "gift"],
        },
    )
    root.add_event("cache.miss", attributes={"key": "cart:A-1024"}, timestamp=EVENT_AT)

    child = tracer.start_span(
        "validate", context=trace.set_span_in_context(root), kind=SpanKind.INTERNAL,
        start_time=CHILD_START, attributes={"valid": True},
    )
    child.set_status(Status(StatusCode.OK))
    child.end(end_time=CHILD_END)

    root.set_attribute("http.response.status_code", 200)
    root.set_status(Status(StatusCode.ERROR, "card declined"))
    root.end(end_time=END)

    ctx = trace.set_span_in_context(root)
    # No spaces in a value: Python's baggage propagator writes a space as `+`,
    # which W3C Baggage does not allow (a `+` is a literal plus there). The
    # divergence is in the reference, not in the format, so the recorded scenario
    # stays inside the grammar and `baggage_test.mbt` covers the encoding rule.
    ctx = baggage.set_baggage("userId", "alice", context=ctx)
    ctx = baggage.set_baggage("serverNode", "DF28", context=ctx)
    ctx = baggage.set_baggage("note", "café", context=ctx)

    headers = {}
    TraceContextTextMapPropagator().inject(headers, context=ctx)
    W3CBaggagePropagator().inject(headers, context=ctx)

    return {
        "spans": [span_json(span) for span in exporter.spans],
        "headers": {key: headers[key] for key in sorted(headers)},
    }


def ratio_decisions():
    """What `TraceIdRatioBased` decides for fixed trace ids, which is the one part
    of a sampler a replayed run can check against another implementation."""
    trace_ids = [
        0x00000000000000000000000000000001,
        0x4BF92F3577B34DA6A3CE929D0E0E4736,
        0x1234567890ABCDEF1234567890ABCDEF,
        0xFEDCBA0987654321FEDCBA0987654321,
        0x0123456789ABCDEF0000000000000000,
        0x0123456789ABCDEF7FFFFFFFFFFFFFFF,
        0x0123456789ABCDEFFFFFFFFFFFFFFFFF,
        0x0123456789ABCDEF8000000000000000,
        0x00FFFFFFFFFFFFFFFFFF000000000000,
    ]
    out = []
    for rate in (0.25, 0.5, 0.75):
        sampler = TraceIdRatioBased(rate)
        for trace_id in trace_ids:
            decision = sampler.should_sample(None, trace_id, "op", SpanKind.INTERNAL)
            out.append(
                {
                    "trace_id": format(trace_id, "032x"),
                    "ratio": rate,
                    "sampled": decision.decision.value == 2,
                }
            )
    return out


def main():
    result = scenario()
    result["ratio"] = ratio_decisions()
    json.dump(result, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()

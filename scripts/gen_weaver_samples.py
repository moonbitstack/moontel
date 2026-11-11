"""Turn an OTLP/JSON metrics body into the sample list Weaver's live-check reads.

`weaver registry live-check --input-source <file> --input-format json` takes a JSON
array of samples, not an OTLP export request. This script is the bridge: it reads
the body `06-meter dump` writes and flattens the resource, the scope and every
metric point into the shape the live-check ingester documents.

Usage: python scripts/gen_weaver_samples.py <otlp-metrics.json> <samples.json>
"""

import json
import sys
from pathlib import Path


def any_value(value):
    """The untagged value of an OTLP `AnyValue`."""
    if "stringValue" in value:
        return value["stringValue"]
    if "boolValue" in value:
        return value["boolValue"]
    if "intValue" in value:
        return int(value["intValue"])
    if "doubleValue" in value:
        return value["doubleValue"]
    if "arrayValue" in value:
        return [any_value(item) for item in value["arrayValue"].get("values", [])]
    return None


def attributes(items):
    return [{"name": item["key"], "value": any_value(item["value"])} for item in items or []]


def instrument(metric):
    if "sum" in metric:
        return "counter" if metric["sum"].get("isMonotonic") else "updowncounter"
    if "histogram" in metric:
        return "histogram"
    # A registry has one histogram instrument and no separate exponential one: the
    # difference is the aggregation, which is not a property the registry describes.
    if "exponentialHistogram" in metric:
        return "histogram"
    if "gauge" in metric:
        return "gauge"
    return "gauge"


def data_points(data):
    points = []
    for point in data.get("dataPoints", []):
        sample = {"attributes": attributes(point.get("attributes"))}
        if "asDouble" in point:
            sample["value"] = point["asDouble"]
        elif "asInt" in point:
            sample["value"] = int(point["asInt"])
        # An exponential histogram has no boundary list: its buckets are described by
        # a scale and an offset, so only the aggregate travels to the live check.
        if "scale" in point:
            sample["count"] = int(point.get("count", 0))
            sample["sum"] = point.get("sum", 0.0)
            if "min" in point:
                sample["min"] = point["min"]
            if "max" in point:
                sample["max"] = point["max"]
        if "bucketCounts" in point:
            sample["bucket_counts"] = [int(count) for count in point["bucketCounts"]]
            sample["count"] = int(point["count"])
            sample["sum"] = point["sum"]
            if "min" in point:
                sample["min"] = point["min"]
            if "max" in point:
                sample["max"] = point["max"]
        points.append(sample)
    return points


def samples(body):
    out = []
    for resource_metrics in body.get("resourceMetrics", []):
        resource = resource_metrics.get("resource", {})
        out.append({"resource": {"attributes": attributes(resource.get("attributes"))}})
        for scope_metrics in resource_metrics.get("scopeMetrics", []):
            scope = scope_metrics.get("scope", {})
            out.append(
                {
                    "instrumentation_scope": {
                        "name": scope.get("name", ""),
                        "version": scope.get("version", ""),
                    }
                }
            )
            for metric in scope_metrics.get("metrics", []):
                data = (
                    metric.get("sum")
                    or metric.get("histogram")
                    or metric.get("exponentialHistogram")
                    or metric.get("gauge")
                    or {}
                )
                out.append(
                    {
                        "metric": {
                            "name": metric["name"],
                            "unit": metric.get("unit", ""),
                            "instrument": instrument(metric),
                            "data_points": data_points(data),
                        }
                    }
                )
    return out


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    source, target = Path(sys.argv[1]), Path(sys.argv[2])
    body = json.loads(source.read_text(encoding="utf-8"))
    target.write_text(
        json.dumps(samples(body), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(f"{target}: {len(samples(body))} samples")
    return 0


if __name__ == "__main__":
    sys.exit(main())

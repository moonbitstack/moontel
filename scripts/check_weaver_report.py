"""Assert what a Weaver live-check report has to contain for this repository.

Two registries are checked in CI and they answer different questions:

- `integration/weaver/registry` is this repository's own schema. The example emits
  seven metrics — two distributions, two sums, a gauge and the three the meter
  observes at collection time — so the report must cover seven metrics, seven data
  points and the four GenAI attributes, with no advisory at all.
- the GenAI semantic conventions are the authority for the names and attributes the
  example borrows. Several names in the example are its own demonstration names, so
  the report carries advisories; this script asserts the part that has to hold —
  the registry recognises the one metric and the three attributes it defines.

Usage: python scripts/check_weaver_report.py <report-dir> [--genai]
"""

import json
import sys
from pathlib import Path

GENAI_ATTRIBUTES = [
    "gen_ai.provider.name",
    "gen_ai.operation.name",
    "gen_ai.request.model",
    "gen_ai.response.model",
]

OWN_METRICS = [
    "gen_ai.client.token.usage",
    "gen_ai.client.operation.duration",
    "gen_ai.client.active.requests",
    "gen_ai.client.queue.length",
    "gen_ai.client.tokens.reported",
    "gen_ai.client.workers.reported",
    "moontel.example.latency",
]

# How many data points carry each attribute. The token counter's view drops the
# response model, and the queue gauge's view keeps only the two the metric needs, so
# the four are not carried equally.
ATTRIBUTE_POINTS = {
    "gen_ai.provider.name": 7,
    "gen_ai.operation.name": 7,
    "gen_ai.request.model": 6,
    "gen_ai.response.model": 5,
}


def main():
    report = Path(sys.argv[1]) / "live_check.json"
    genai = "--genai" in sys.argv
    stats = json.loads(report.read_text(encoding="utf-8"))["statistics"]
    metrics = stats.get("seen_registry_metrics", {})
    attributes = stats.get("seen_registry_attributes", {})
    if genai:
        if metrics.get("gen_ai.client.operation.duration") != 1:
            print("the GenAI registry did not recognise the operation duration")
            return 1
        for key in GENAI_ATTRIBUTES:
            wanted = ATTRIBUTE_POINTS[key]
            if attributes.get(key, 0) != wanted:
                print(f"{key}: seen {attributes.get(key, 0)} times, expected {wanted}")
                return 1
        print(
            "the GenAI registry recognised the duration metric and its four "
            f"attributes; {stats.get('advice_level_counts', {}).get('violation', 0)} "
            "advisories remain, and the README says which they are",
        )
        return 0
    by_type = stats.get("total_entities_by_type", {})
    if by_type.get("metric") != 7 or by_type.get("data_point") != 7:
        print(f"expected seven metrics and seven data points, got {by_type}")
        return 1
    for name in OWN_METRICS:
        if metrics.get(name) != 1:
            print(f"{name}: seen {metrics.get(name)} times, expected 1")
            return 1
    for key in GENAI_ATTRIBUTES:
        wanted = ATTRIBUTE_POINTS[key]
        if attributes.get(key) != wanted:
            print(f"{key}: seen {attributes.get(key)} times, expected {wanted}")
            return 1
    if stats.get("total_advisories") != 0:
        print(f"the registry reported {stats.get('total_advisories')} advisories")
        return 1
    if stats.get("registry_coverage") != 1.0:
        print(f"registry coverage is {stats.get('registry_coverage')}, expected 1.0")
        return 1
    print("the seven metrics match the registry: seven points, no advisory")
    return 0


if __name__ == "__main__":
    sys.exit(main())

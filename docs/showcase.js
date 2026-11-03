// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The showcase: a traceparent goes in, the library answers. Both calls below are
// `@propagate.parse` and a real tracer's `start` + `inject`, compiled to JavaScript
// by `docs.yml`; this file only lays the answers out.

const parse = globalThis.moontelParse;
const hop = globalThis.moontelHop;
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

const input = $("#tp-input");
const stateInput = $("#ts-input");
const segments = $("#segments");
const status = $("#lab-status");
const fields = $("#fields");
const hopButton = $("#hop-button");
const hopHeader = $("#hop-header");
const hopCompare = $("#hop-compare");

const DEFAULT = input.value;

function node(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

/* ------------------------------------------------------------ the parse */

// The four fields, drawn the way the header is written: each one underlined, with its
// name beneath. The values come from the library; the dashes are punctuation and are
// drawn between them.
function drawFields(result, text) {
  segments.replaceChildren();
  const version = text.trim().slice(0, 2) || "00";
  const parts = [
    ["version", version, "02"],
    ["trace id", result.trace_id, "32"],
    ["span id", result.span_id, "16"],
    ["flags", result.flags, "01"],
  ];
  parts.forEach(([name, value, width], index) => {
    if (index > 0) segments.append(node("span", "seg-dash", "–"));
    const group = node("span", "seg");
    group.dataset.field = name.replace(" ", "-");
    group.append(node("b", "seg-value", value));
    segments.append(group);
  });
  segments.dataset.mode = "fields";
}

// A refused header is one string; the reader needs the offset, so the string is
// drawn with every character placeable and the one that failed marked.
function drawRaw(text, at) {
  segments.replaceChildren();
  const raw = node("span", "raw");
  [...text].forEach((character, index) => {
    const span = node("span", "raw-char", character);
    if (index === at) span.className += " is-bad";
    raw.append(span);
  });
  segments.append(raw);
  segments.dataset.mode = "raw";
}

function parseNow() {
  if (!parse) {
    status.textContent = "The engine did not load, so the parser cannot be asked.";
    return;
  }
  const text = input.value;
  const result = parse(text);
  if (result.ok) {
    drawFields(result, text);
    status.className = "lab-status is-ok";
    status.innerHTML = [
      `<b>accepted</b>`,
      `${text.length} characters`,
      `flags ${result.flags}`,
      result.sampled ? "sampled" : "not sampled",
      result.random ? "random bit set" : "random bit clear",
    ].join(" · ");
    fields.replaceChildren(
      ...[
        ["version", text.trim().slice(0, 2)],
        ["trace id", result.trace_id],
        ["span id", result.span_id],
        ["flags", `${result.flags} · bit 0 ${result.sampled ? "set" : "clear"}, bit 1 ${result.random ? "set" : "clear"}`],
        ["context", result.valid ? "a trace to join" : "not a trace to join"],
      ].map(([name, value]) => {
        const row = node("div", "lab-field");
        row.append(node("dt", "", name));
        row.append(node("dd", "", value));
        return row;
      }),
    );
  } else {
    drawRaw(text, result.at);
    status.className = "lab-status is-refused";
    const where = result.at >= 0 ? `at character ${result.at}` : "";
    status.innerHTML = [`<b>refused</b>`, result.kind, where, result.want ? `wanted ${result.want}` : ""]
      .filter(Boolean)
      .join(" · ");
    fields.replaceChildren();
  }
}

/* ------------------------------------------------------------ the hop */

function hopNow() {
  if (!hop) {
    hopHeader.textContent = "The engine did not load, so no hop can be made.";
    return;
  }
  const result = hop(input.value, stateInput.value);
  if (!result.ok) {
    hopHeader.textContent = result.reason;
    hopCompare.replaceChildren();
    return;
  }
  hopHeader.textContent = result.traceparent;
  const rows = [
    ["trace id", result.linked ? "kept" : "new trace", result.trace_id],
    ["parent span", result.linked ? "from the header" : "none", result.parent_span_id || "—"],
    ["this span", "minted here", result.span_id],
    [
      "tracestate",
      result.tracestate_kept ? "kept" : result.tracestate ? "rewritten" : "not carried",
      result.tracestate || "—",
    ],
  ];
  hopCompare.replaceChildren();
  for (const [name, verdict, value] of rows) {
    const row = node("div", "compare-row");
    row.append(node("dt", "", name));
    row.append(node("dd", "compare-verdict", verdict));
    row.append(node("dd", "compare-value", value));
    if (name === "this span" || (name === "trace id" && result.linked)) {
      row.classList.add("is-accent");
    }
    hopCompare.append(row);
  }
  if (!result.linked) {
    hopHeader.setAttribute("title", "The header could not be read, so this hop started a new trace.");
  } else {
    hopHeader.removeAttribute("title");
  }
}

/* ------------------------------------------------------------ wiring */

let timer = 0;
input.addEventListener("input", () => {
  clearTimeout(timer);
  timer = setTimeout(parseNow, 90);
});

for (const preset of $$(".preset")) {
  preset.addEventListener("click", () => {
    input.value = preset.dataset.tp;
    parseNow();
    hopNow();
  });
}

hopButton.addEventListener("click", hopNow);
stateInput.addEventListener("input", () => {
  clearTimeout(timer);
  timer = setTimeout(hopNow, 120);
});

// A page that opened with the engine's own header is showing the trace the rest of
// the sheet draws, not a string typed into the HTML.
if (globalThis.moontelTrace) {
  input.value = globalThis.moontelTrace.traceparent;
} else {
  input.value = DEFAULT;
}
parseNow();
hopNow();

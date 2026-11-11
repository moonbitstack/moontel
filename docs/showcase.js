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

/* ------------------------------------------------------- the distribution */

// One set of latencies, recorded into two histograms by the library. The control
// only chooses how wide the input is; the bucket counts below are `@meter`'s.
const distribution = globalThis.moontelDistribution;
const spreadInput = $("#spread");
const spreadValue = $("#spread-value");
const explicitSvg = $("#explicit");
const exponentialSvg = $("#exponential");
const explicitNote = $("#explicit-note");
const exponentialNote = $("#exponential-note");
const facts = $("#spectrum-facts");
const axis = $("#spectrum-axis");

// The frame both rows share: a logarithmic axis from half a millisecond to eight
// seconds. It does not move with the control, so the picture can be compared with
// itself.
const DOMAIN = [0.0005, 8];
const WIDTH = 1000;
const BASELINE = 94;

function xOf(value) {
  const lo = Math.log(DOMAIN[0]);
  const hi = Math.log(DOMAIN[1]);
  const clamped = Math.min(Math.max(value, DOMAIN[0]), DOMAIN[1]);
  return ((Math.log(clamped) - lo) / (hi - lo)) * WIDTH;
}

function seconds(value) {
  if (value < 0.001) return `${(value * 1e6).toFixed(0)} µs`;
  if (value < 1) return `${(value * 1000).toFixed(value < 0.01 ? 1 : 0)} ms`;
  return `${value.toFixed(2)} s`;
}

// Every value interpolated into this string is a number this page computed, so the
// markup cannot carry anything but a bar.
function bars(cells, tallest) {
  const parts = [];
  for (const cell of cells) {
    if (cell.count === 0) continue;
    const left = xOf(cell.from);
    const right = Math.max(xOf(cell.to), left + 1.2);
    const height = (cell.count / tallest) * (BASELINE - 8);
    const accent = cell.count === tallest ? " is-tallest" : "";
    parts.push(
      `<rect class="bar${accent}" x="${left.toFixed(2)}" y="${(BASELINE - height).toFixed(2)}" ` +
        `width="${(right - left).toFixed(2)}" height="${height.toFixed(2)}">` +
        `<title>${seconds(cell.from)} – ${seconds(cell.to)} · ${cell.count}</title></rect>`,
    );
  }
  return parts.join("");
}

function drawChart(svg, cells, tallest, marker) {
  const body = bars(cells, tallest);
  const line = marker === undefined
    ? ""
    : `<line class="exemplar-mark" x1="${xOf(marker.value)}" x2="${xOf(marker.value)}" y1="4" y2="${BASELINE}">` +
      `<title>exemplar · ${seconds(marker.value)} · trace ${marker.trace}</title></line>`;
  svg.innerHTML = `${body}${line}`;
}

function drawAxis() {
  const ticks = [
    [0.001, "1 ms"],
    [0.01, "10 ms"],
    [0.1, "100 ms"],
    [1, "1 s"],
  ];
  axis.innerHTML = ticks
    .map(([value, label]) => {
      const at = (xOf(value) / WIDTH) * 100;
      return `<span style="left:${at.toFixed(2)}%">${label}</span>`;
    })
    .join("");
}

function fact(name, value) {
  return `<div><dt>${name}</dt><dd>${value}</dd></div>`;
}

function spectrumNow() {
  const note = (message) => {
    explicitNote.textContent = message;
    exponentialNote.textContent = message;
  };
  if (!distribution) {
    note("The engine did not load, so nothing can be counted.");
    return;
  }
  const spread = Number(spreadInput.value) / 100;
  spreadValue.textContent = spread.toFixed(2);
  const result = distribution(spread);
  const explicit = result.explicit;
  const exponential = result.exponential;

  // An explicit bucket is the interval between two boundaries; the first starts at
  // zero and the last never ends, so both are clamped to the frame.
  const explicitCells = explicit.counts.map((count, index) => ({
    from: index === 0 ? DOMAIN[0] : explicit.bounds[index - 1],
    to: index === explicit.counts.length - 1 ? DOMAIN[1] : explicit.bounds[index],
    count,
  }));
  const explicitTallest = Math.max(...explicit.counts, 1);
  const used = explicit.counts.filter((count) => count > 0).length;
  explicitNote.textContent = `${used} of ${explicit.counts.length} buckets used`;
  drawChart(explicitSvg, explicitCells, explicitTallest);

  // An exponential bucket i covers (2^(i/2^scale), 2^((i+1)/2^scale)].
  const magnification = Math.pow(2, exponential.scale);
  const exponentialCells = exponential.counts.map((count, index) => {
    const bucket = exponential.offset + index;
    return {
      from: Math.pow(2, bucket / magnification),
      to: Math.pow(2, (bucket + 1) / magnification),
      count,
    };
  });
  const exponentialTallest = Math.max(...exponential.counts, 1);
  exponentialNote.textContent =
    `scale ${exponential.scale} · ${exponential.counts.length} buckets`;
  drawChart(exponentialSvg, exponentialCells, exponentialTallest, result.exemplar || undefined);

  facts.innerHTML = [
    fact("requests", String(result.requests)),
    fact("fastest", seconds(explicit.min)),
    fact("slowest", seconds(explicit.max)),
    fact("recorded", `${exponential.count} in both`),
  ].join("");
}

drawAxis();
spreadInput.addEventListener("input", spectrumNow);
for (const preset of $$("[data-spread]")) {
  preset.addEventListener("click", () => {
    spreadInput.value = preset.dataset.spread;
    spectrumNow();
  });
}
spectrumNow();

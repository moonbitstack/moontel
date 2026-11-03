// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Draws the sheet from what the library produced, and runs the three motions: the
// line drawing itself, the loupe over a span, and the sampler thinning the strip.
//
// Every number, id and header on the page arrives from `engine/moontel.js`, which is
// this library compiled to JavaScript. This file lays them out and does nothing else
// — no span is invented here, and no sampling decision is computed here.

const data = globalThis.moontelTrace;
const kept = globalThis.moontelKept;
const $ = (selector) => document.querySelector(selector);
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

/* ------------------------------------------------------------ the facts */

function fillFacts() {
  if (!data) return;
  const spans = data.spans;
  // How deep the tree goes, which is a fact about the trace; how many "services" it
  // touched is not, because a span name is not a service and the sample carries no
  // `service.name` attribute.
  const byId = new Map(spans.map((span) => [span.id, span]));
  const depth = (span) => {
    let steps = 0;
    let cursor = span;
    const seen = new Set();
    while (cursor.parent && byId.has(cursor.parent) && !seen.has(cursor.id)) {
      seen.add(cursor.id);
      cursor = byId.get(cursor.parent);
      steps += 1;
    }
    return steps;
  };
  const levels = Math.max(...spans.map(depth)) + 1;
  const cells = document.querySelectorAll("#facts .fact");
  cells[0].innerHTML = `<b>${(data.duration_us / 1000).toFixed(1)}</b> ms`;
  cells[1].innerHTML = `<b>${spans.length}</b> spans`;
  cells[2].innerHTML = `<b>${levels}</b> levels`;
  cells[3].innerHTML = `<b>${data.dropped ?? 0}</b> dropped`;
  const colophon = $("#colophon-time");
  if (colophon) {
    colophon.textContent = `${(data.duration_us / 1000).toFixed(1)} ms · ${spans.length} spans`;
  }
  const end = $("#end-duration");
  if (end) {
    end.textContent = `${(data.duration_us / 1000).toFixed(1)} milliseconds.`;
  }
  const heroEnd = $("#hero-end");
  if (heroEnd) {
    heroEnd.textContent = `${(data.duration_us / 1000).toFixed(1)} ms · ${spans.length} spans`;
  }
}

/* ------------------------------------------------------------ the hero line */

(function drawHero() {
  const svg = $("#hero-line");
  const dash = svg.querySelector(".draw");
  dash.style.setProperty("--len", "1200");
  if (reduceMotion) {
    svg.classList.add("is-drawn");
    return;
  }
  requestAnimationFrame(() => requestAnimationFrame(() => svg.classList.add("is-drawn")));
})();

/* ------------------------------------------------------------ the trace plate */

// The tree, as a depth-first walk: a span and then what happened inside it. This is
// layout, not lineage — the parent ids come from the library.
function rowsOf(spans) {
  const children = new Map();
  let root = null;
  for (const span of spans) {
    if (span.parent === null) {
      root = span;
      continue;
    }
    if (!children.has(span.parent)) children.set(span.parent, []);
    children.get(span.parent).push(span);
  }
  const rows = [];
  const walk = (span, depth) => {
    rows.push({ ...span, depth });
    const kids = (children.get(span.id) || []).sort((a, b) => a.start - b.start);
    for (const kid of kids) walk(kid, depth + 1);
  };
  if (root) walk(root, 0);
  return rows;
}

function renderTrace() {
  const host = $("#trace");
  const svg = $("#trace-svg");
  if (!data) {
    host.hidden = true;
    return;
  }
  const width = host.clientWidth;
  const narrow = width < 700;
  const gutter = narrow ? 0 : 208;
  const labelColumn = 78;
  const idColumn = 58;
  const right = narrow ? 12 : labelColumn + idColumn + 14;
  const axis = 34;
  const rowHeight = narrow ? 54 : 52;
  const rows = rowsOf(data.spans);
  const height = axis + rows.length * rowHeight + 6;
  const plot = width - gutter - right;
  const x = (micros) => gutter + (micros / data.duration_us) * plot;
  const durationColumn = width - idColumn - 8;
  const idEnd = width - 2;

  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.setAttribute("width", width);
  svg.setAttribute("height", height);

  const ns = "http://www.w3.org/2000/svg";
  const make = (name, attrs) => {
    const node = document.createElementNS(ns, name);
    for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
    return node;
  };
  const text = (x0, y0, body, cls, anchor = "start") => {
    const node = make("text", { x: x0, y: y0, class: cls, "text-anchor": anchor });
    node.textContent = body;
    return node;
  };
  svg.replaceChildren();

  // the axis: five-millisecond steps on a wide sheet, ten when the labels would
  // start to run into each other, then the end of the request where it stops.
  const step = narrow ? 10 : 5;
  for (let t = 0; t <= data.duration_us / 1000; t += step) {
    const at = x(t * 1000);
    svg.append(make("line", { x1: at, y1: axis - 5, x2: at, y2: height - 4, class: "grid-line" }));
    // The last label would run off the sheet: it is set inside the plot instead.
    const overflows = at + 34 > width - right;
    svg.append(text(overflows ? at - 4 : at + 4, axis - 12, t === 0 ? "0" : `${t} ms`, "", overflows ? "end" : "start"));
  }
  const endX = x(data.duration_us);
  svg.append(make("line", { x1: endX, y1: axis - 5, x2: endX, y2: height - 4, class: "axis" }));
  svg.append(make("line", { x1: gutter, y1: axis, x2: endX, y2: axis, class: "axis" }));

  rows.forEach((span, index) => {
    const centre = axis + index * rowHeight + rowHeight / 2 + 6;
    const from = x(span.start);
    const to = x(span.end);
    const group = make("g", { class: "row", "data-index": index });

    if (!narrow) {
      // Names hang in one column, right-aligned against the axis: the tree is read
      // from the order of the rows and from the readout, not from a ragged indent.
      const indent = gutter - 16;
      group.append(text(indent, centre - 2, span.name, "row-name", "end"));
      group.append(text(indent, centre + 14, span.kind, "row-kind", "end"));
    } else {
      // Narrow: the name sits above its bar at the left edge, so a span that starts
      // late does not push its own label off the sheet.
      group.append(text(2, centre - 14, span.name, "row-name"));
      group.append(text(2, centre - 26, span.kind, "row-kind"));
    }

    // the measure: a two-pixel rule with a cap at each end, the way a dimension is
    // drawn on a plan
    group.append(make("line", { x1: from, y1: centre, x2: to, y2: centre, class: "bar-body" }));
    group.append(make("line", { x1: from, y1: centre - 6, x2: from, y2: centre + 6, class: "bar" }));
    group.append(make("line", { x1: to, y1: centre - 6, x2: to, y2: centre + 6, class: "bar" }));

    // an event rises from its span, the way a mark sits on a rule
    for (const [name, at] of span.events) {
      const ex = x(at);
      group.append(make("line", { x1: ex, y1: centre - 5, x2: ex, y2: centre - 15, class: "event-stem" }));
      group.append(make("circle", { cx: ex, cy: centre - 17, r: 1.8, class: "event" }));
      if (!narrow) group.append(text(ex + 6, centre - 20, name, "row-kind"));
    }

    if (!narrow) {
      const micros = Math.round(span.end - span.start);
      const label = micros >= 1000 ? `${(micros / 1000).toFixed(1)} ms` : `${micros} µs`;
      group.append(text(durationColumn, centre + 4, label, "row-time", "end"));
      group.append(text(idEnd, centre + 4, span.id.slice(0, 6), "row-kind", "end"));
    }

    svg.append(group);
  });

  // the loupe: one row lit, the rest dropped back
  const readout = $("#trace-readout");
  const clear = () => {
    svg.classList.remove("has-active");
    svg.querySelectorAll(".row").forEach((row) => row.classList.remove("is-active"));
    readout.innerHTML = "<span><b>Rest the pointer on a span.</b></span>";
  };
  const show = (index) => {
    const span = rows[index];
    svg.classList.add("has-active");
    svg.querySelectorAll(".row").forEach((row, at) => {
      row.classList.toggle("is-active", at === index);
    });
    const micros = Math.round(span.end - span.start);
    const attributes = span.attributes
      .map(([key, value]) => `<span class="attrs">${key}=${value}</span>`)
      .join(" ");
    readout.innerHTML = [
      `<span><b>${span.name}</b> · ${span.kind}</span>`,
      `<span>${micros >= 1000 ? (micros / 1000).toFixed(2) : micros} ${micros >= 1000 ? "ms" : "µs"} · ${span.start.toFixed(1)} → ${span.end.toFixed(1)} µs</span>`,
      `<span>span…${span.id.slice(-6)} · ${span.parent ? `under span…${span.parent.slice(-6)}` : "root"}</span>`,
      `<span class="attrs">${attributes}</span>`,
    ].join("");
  };

  svg.addEventListener("pointermove", (event) => {
    const box = svg.getBoundingClientRect();
    const y = ((event.clientY - box.top) / box.height) * height;
    const index = Math.floor((y - axis - 6) / rowHeight);
    if (index >= 0 && index < rows.length) show(index);
    else clear();
  });
  svg.addEventListener("pointerleave", clear);
}

/* ------------------------------------------------------------ the header */

function fillSpecimen() {
  if (!data) return;
  const specimen = $("#specimen");
  const parts = data.traceparent.split("-");
  for (const [name, value] of [
    ["version", parts[0]],
    ["trace", parts[1]],
    ["span", parts[2]],
    ["flags", parts[3]],
  ]) {
    specimen.querySelector(`[data-field="${name}"]`).textContent = value;
  }
  // The copy caption reads this, so what leaves the page is the header the library
  // wrote rather than the text nodes a reader happens to drag over.
  specimen.dataset.copyText = data.traceparent;
  // The notes hang under the field they name: measuring the fields after the text is
  // set is the only way they stay aligned. Two notes that would collide are stacked on
  // two levels, the way a drawing labels a narrow part, and each gets a rule of its
  // own reaching up to the specimen.
  const notes = [...document.querySelectorAll("#annotations .annotation")];
  const ticks = [];
  let previousRight = -Infinity;
  let level = 0;
  notes.forEach((note, index) => {
    const field = specimen.querySelector(`[data-field="${note.dataset.for}"]`);
    if (!field) return;
    note.style.left = `${field.offsetLeft}px`;
    if (field.offsetLeft < previousRight + 12) level = level === 0 ? 1 : 0;
    else level = 0;
    note.classList.toggle("is-lifted", level === 1);
    const tick = document.createElement("span");
    tick.className = "tick";
    tick.style.left = `${field.offsetLeft}px`;
    // A lifted note keeps its rule reaching all the way up to the specimen.
    tick.style.height = level === 1 ? "44px" : "8px";
    ticks.push(tick);
    previousRight = field.offsetLeft + Math.max(40, note.offsetWidth);
  });
  for (const tick of ticks) $("#annotations").append(tick);
}

/* ------------------------------------------------------------ the decision */

const strip = $("#strip");
const counter = $("#counter");
const stripReadout = $("#strip-readout");
const stops = [...document.querySelectorAll(".stop")];
let ids = data ? data.strip : [];
let ticks = [];
let ratio = 0.5;

function buildStrip() {
  strip.replaceChildren();
  ticks = ids.map((id, index) => {
    const tick = document.createElement("i");
    tick.dataset.index = index;
    tick.dataset.id = id;
    strip.append(tick);
    return tick;
  });
}

function applyRatio(next) {
  ratio = next;
  for (const stop of stops) {
    stop.setAttribute("aria-pressed", String(Number(stop.dataset.ratio) === next));
  }
  if (!kept) {
    stripReadout.innerHTML =
      "<b>The engine did not load</b> · the sampler cannot be asked, so the strip is left as it is";
    return;
  }
  const decided = kept(next).kept;
  let sample = 0;
  ticks.forEach((tick, index) => {
    const yes = Boolean(decided[index]);
    tick.classList.toggle("kept", yes);
    if (yes) sample += 1;
  });
  const label = stops.find((stop) => Number(stop.dataset.ratio) === next).textContent;
  counter.innerHTML = `<b>${sample}</b> of ${ticks.length} sampled`;
  stripReadout.innerHTML = `<b>${ticks.length} requests</b> · each a trace id this library sampled for real, at a rate of ${label}`;
}

strip.addEventListener("pointermove", (event) => {
  const tick = event.target.closest("i");
  if (!tick) return;
  const was = strip.querySelector(".is-pointed");
  if (was) was.classList.remove("is-pointed");
  tick.classList.add("is-pointed");
  const index = Number(tick.dataset.index);
  const verdict = tick.classList.contains("kept") ? "kept" : "dropped";
  stripReadout.innerHTML = `#${String(index + 1).padStart(3, "0")} · <b>${tick.dataset.id}</b> · ${verdict}`;
});

strip.addEventListener("pointerleave", () => {
  const was = strip.querySelector(".is-pointed");
  if (was) was.classList.remove("is-pointed");
  counterAndCaption();
});

function counterAndCaption() {
  if (!kept) return;
  const sample = ticks.filter((tick) => tick.classList.contains("kept")).length;
  const label = stops.find((stop) => Number(stop.dataset.ratio) === ratio).textContent;
  counter.innerHTML = `<b>${sample}</b> of ${ticks.length} sampled`;
  stripReadout.innerHTML = `<b>${ticks.length} requests</b> · each a trace id this library sampled for real, at a rate of ${label}`;
}

for (const stop of stops) {
  stop.addEventListener("click", () => applyRatio(Number(stop.dataset.ratio)));
}

/* ------------------------------------------------------------ start */

fillFacts();
fillSpecimen();
buildStrip();
// A link can open on a rate as well as on a plate: `?rate=0.1`.
const asked = Number(new URLSearchParams(location.search).get("rate"));
applyRatio(stops.some((stop) => Number(stop.dataset.ratio) === asked) ? asked : ratio);
renderTrace();

// A deep link to a plate would land short: the trace is drawn after the first layout,
// which moves everything below it. Once the sheet is drawn, the plate the link named
// is scrolled to again.
if (location.hash) {
  const target = document.querySelector(location.hash);
  if (target) scrollTo(0, target.offsetTop);
}

let resizeFrame = 0;
addEventListener("resize", () => {
  cancelAnimationFrame(resizeFrame);
  resizeFrame = requestAnimationFrame(renderTrace);
});

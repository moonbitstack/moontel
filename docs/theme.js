// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Chosen before the first paint, or a reader who asked for paper sees a black flash
// on the way to it. Kept as its own blocking script for that reason: a module would
// be deferred, and the flash would be back.
//
// A link can name the plate it was printed on: `?plate=paper` or `?plate=ink`. The
// stored choice comes next, then whatever the reader's system prefers.
(() => {
  const asked = new URLSearchParams(location.search).get("plate");
  const stored = localStorage.getItem("moontel-plate");
  const preferred = matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  document.documentElement.dataset.theme =
    asked === "paper"
      ? "light"
      : asked === "ink"
        ? "dark"
        : stored === "light" || stored === "dark"
          ? stored
          : preferred;
})();

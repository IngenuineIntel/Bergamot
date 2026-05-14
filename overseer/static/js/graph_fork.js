"use strict";

(() => {
  const common = window.BergamotCommon;
  // Max retained rows is controlled by common.MAX_FEED_ROWS.
  const feeds = window.BergamotFeeds;
  const tbody = document.getElementById("fork-body");
  if (!tbody || !feeds) return;

  function prependForkRow(ev) {
    feeds.prependLimitedRow(
      tbody,
      `
    <td>${common.fmtEventTs(ev.ts_s, ev.ts_ms, 3)}</td>
    <td>${common.esc(ev.pid ?? "")}</td>
    <td>${common.esc(ev.ppid ?? "")}</td>
    <td>${common.esc(ev.uid ?? "")}</td>
    <td>${common.esc(ev.comm ?? "")}</td>
    <td class="arg-cell">${common.esc(ev.arg ?? "")}</td>
  `
    );
  }

  async function loadSnapshot() {
    const events = await fetch("/api/fork").then((r) => r.json());
    if (!Array.isArray(events)) return;
    feeds.renderRecentRows(events, prependForkRow);
  }

  common.connectEventStream({
    onEvent: (ev) => {
      if (ev?.type === "fork") prependForkRow(ev);
    },
  });

  loadSnapshot().catch((err) => {
    console.warn("Fork snapshot failed:", err);
  });

  common.initResizableTables();
})();

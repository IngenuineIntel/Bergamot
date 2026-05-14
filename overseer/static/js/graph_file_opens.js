"use strict";

(() => {
  const common = window.BergamotCommon;
  // Max retained rows is controlled by common.MAX_FEED_ROWS.
  const feeds = window.BergamotFeeds;
  const tbody = document.getElementById("open-body");
  if (!tbody || !feeds) return;

  function prependOpenRow(ev) {
    feeds.prependLimitedRow(
      tbody,
      `
    <td>${common.fmtEventTs(ev.ts_s, ev.ts_ms, 3)}</td>
    <td>${ev.pid}</td>
    <td>${common.esc(ev.comm)}</td>
    <td class="arg-cell">${common.esc(common.packetArg1(ev))}</td>
    <td class="arg-cell">${common.esc(common.packetArg2(ev))}</td>
  `
    );
  }

  async function loadSnapshot() {
    const opens = await fetch("/api/file_opens").then((r) => r.json());
    if (!Array.isArray(opens)) return;
    feeds.renderRecentRows(opens, prependOpenRow);
  }

  common.connectEventStream({
    onEvent: (ev) => {
      if (ev?.type === "open") prependOpenRow(ev);
    },
  });

  loadSnapshot().catch((err) => {
    console.warn("File opens snapshot failed:", err);
  });

  common.initResizableTables();
})();

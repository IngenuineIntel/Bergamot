"use strict";

(() => {
  const common = window.BergamotCommon;
  // Max retained rows is controlled by common.MAX_FEED_ROWS.
  const feeds = window.BergamotFeeds;
  const tbody = document.getElementById("net-body");
  if (!tbody || !feeds) return;

  function prependNetworkRow(ev) {
    feeds.prependLimitedRow(
      tbody,
      `
    <td>${common.fmtEventTs(ev.ts_s, ev.ts_ms, 3)}</td>
    <td>${ev.pid}</td>
    <td>${common.esc(ev.comm)}</td>
    <td class="arg-cell">${common.esc(common.packetArg1(ev))}</td>
  `
    );
  }

  async function loadSnapshot() {
    const nets = await fetch("/api/network").then((r) => r.json());
    if (!Array.isArray(nets)) return;
    feeds.renderRecentRows(nets, prependNetworkRow);
  }

  common.connectEventStream({
    onEvent: (ev) => {
      if (ev?.type === "connect") prependNetworkRow(ev);
    },
  });

  loadSnapshot().catch((err) => {
    console.warn("Network snapshot failed:", err);
  });

  common.initResizableTables();
})();

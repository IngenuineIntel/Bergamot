"use strict";

(() => {
  const common = window.BergamotCommon;
  // Max retained rows is controlled by common.MAX_FEED_ROWS.
  const feeds = window.BergamotFeeds;
  const tbody = document.getElementById("syscalls-body");
  if (!tbody || !feeds) return;

  function prependSyscallRow(ev) {
    feeds.prependLimitedRow(
      tbody,
      `
    <td>${common.fmtEventTs(ev.ts_s, ev.ts_ms, 3)}</td>
    <td>${common.esc(ev.pid ?? "")}</td>
    <td>${common.esc(ev.ppid ?? "")}</td>
    <td>${common.esc(ev.uid ?? "")}</td>
    <td>${common.esc(common.packetType(ev))}</td>
    <td>${common.esc(ev.comm ?? "")}</td>
    <td class="arg-cell">${common.esc(common.packetArg1(ev))}</td>
    <td class="arg-cell">${common.esc(common.packetArg2(ev))}</td>
    <td>${common.esc(common.packetRetval(ev))}</td>
  `
    );
  }

  function shouldRenderEvent(ev) {
    if (!ev || typeof ev !== "object") return false;
    if (ev.kind === "system_perf") return false;
    if (ev.kind === "proc_snapshot" || ev.kind === "rich_proc_snapshot") return false;
    return typeof ev.type === "string" && !!ev.type;
  }

  async function loadSnapshot() {
    const events = await fetch("/api/events/db").then((r) => r.json());
    if (!Array.isArray(events)) return;
    feeds.renderRecentRows(events, prependSyscallRow);
  }

  common.connectEventStream({
    onEvent: (ev) => {
      if (shouldRenderEvent(ev)) prependSyscallRow(ev);
    },
  });

  loadSnapshot().catch((err) => {
    console.warn("Syscalls snapshot failed:", err);
  });

  common.initResizableTables();
})();

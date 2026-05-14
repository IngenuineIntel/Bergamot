"use strict";

(() => {
  const common = window.BergamotCommon;
  const processes = window.BergamotProcesses;
  // Debounce delay before reloading lifecycle rows after relevant events.
  const LIFECYCLE_REFRESH_DELAY_MS = 600;
  // How often process snapshots are polled for hover-detail enrichment.
  const PROCESS_REFRESH_INTERVAL_MS = 2000;

  const body = document.getElementById("lifecycle-body");
  if (!body || !processes) return;

  const procMap = processes.createProcessMap();
  const hover = processes.createProcessHoverController(procMap);
  let refreshTimer = null;

  function renderRows(rows) {
    const fragment = document.createDocumentFragment();

    rows.forEach((row) => {
      const liveProc = procMap[row.pid] || {};
      const tr = document.createElement("tr");
      hover.bindRow(tr, row, "lifecycle");
      tr.innerHTML = `
      <td>${common.fmtEventTs(row.start_ts_s, row.start_ts_ms, 3)}</td>
      <td>${common.fmtEventTs(row.last_ts_s, row.last_ts_ms, 3)}</td>
      <td>${common.esc(row.pid ?? "")}</td>
      <td>${common.esc(row.ppid ?? "")}</td>
      <td>${common.esc(row.uid ?? "")}</td>
      <td>${common.esc(row.comm ?? "")}</td>
      <td class="arg-cell">${common.esc(row.exec_arg ?? "")}</td>
      <td>${common.fmtCpuPct(row.cpu_pct ?? liveProc.cpu_pct)}</td>
      <td>${common.fmtRssKb(row.vm_rss_kb ?? liveProc.vm_rss_kb)}</td>
    `;
      fragment.appendChild(tr);
    });

    body.replaceChildren(fragment);
    hover.syncAfterRowsRender();
  }

  async function loadProcesses() {
    try {
      const procs = await fetch("/api/processes").then((r) => r.json());
      if (Array.isArray(procs)) processes.replaceProcessMap(procMap, procs);
    } catch (_) {
      // Hover panel can still work with lifecycle row values only.
    }
  }

  async function loadLifecycleSnapshot() {
    const rows = await fetch("/api/lifecycle").then((r) => r.json());
    renderRows(Array.isArray(rows) ? rows : []);
  }

  function scheduleRefresh() {
    if (refreshTimer) return;
    refreshTimer = setTimeout(() => {
      refreshTimer = null;
      loadLifecycleSnapshot().catch(() => {});
    }, LIFECYCLE_REFRESH_DELAY_MS);
  }

  common.connectEventStream({
    onEvent: (ev) => {
      if (ev?.kind === "rich_proc_snapshot" || ev?.kind === "proc_snapshot") {
        processes.applyProcessSnapshot(procMap, ev);
        scheduleRefresh();
        return;
      }

      if (ev?.type === "fork" || ev?.type === "execve" || ev?.type === "open" || ev?.type === "connect") {
        scheduleRefresh();
      }
    },
  });

  Promise.all([loadProcesses(), loadLifecycleSnapshot()]).catch((err) => {
    console.warn("Lifecycle snapshot failed:", err);
  });

  setInterval(() => {
    loadProcesses();
  }, PROCESS_REFRESH_INTERVAL_MS);

  common.initResizableTables();
})();

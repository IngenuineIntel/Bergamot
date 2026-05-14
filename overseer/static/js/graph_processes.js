"use strict";

(() => {
  const common = window.BergamotCommon;
  const processes = window.BergamotProcesses;
  // How often table DOM updates are applied when new process data arrives.
  const PROCESS_RENDER_INTERVAL_MS = 1000;
  // How often process snapshots are polled from the API.
  const PROCESS_REFRESH_INTERVAL_MS = 2000;

  const procBody = document.getElementById("proc-body");
  const procTable = document.getElementById("proc-table");
  if (!procBody || !procTable || !processes) return;

  const procMap = processes.createProcessMap();
  let procSortCol = "pid";
  let procSortAsc = true;
  let procDirty = false;

  function renderProcs() {
    const rows = Object.values(procMap);
    rows.sort((a, b) => {
      const av = a[procSortCol] ?? "";
      const bv = b[procSortCol] ?? "";
      if (av < bv) return procSortAsc ? -1 : 1;
      if (av > bv) return procSortAsc ? 1 : -1;
      return 0;
    });

    const fragment = document.createDocumentFragment();

    rows.forEach((p) => {
      const tr = document.createElement("tr");
      tr.innerHTML = `
      <td>${p.pid}</td>
      <td>${p.ppid}</td>
      <td>${p.uid}</td>
      <td>${common.esc(p.comm)}</td>
      <td>${p.threads ?? 0}</td>
      <td>${common.fmtCpuPct(p.cpu_pct)}</td>
      <td>${common.fmtRssKb(p.vm_rss_kb)}</td>
      <td>${common.fmtEventTs(p.last_seen_s, p.last_seen_ms, 3)}</td>
    `;
      fragment.appendChild(tr);
    });

    procBody.replaceChildren(fragment);
  }

  async function refreshProcessesFromApi() {
    try {
      const procs = await fetch("/api/processes").then((r) => r.json());
      if (!Array.isArray(procs)) return;
      processes.replaceProcessMap(procMap, procs);
      procDirty = true;
    } catch (_) {
      // Keep existing table contents if refresh fails.
    }
  }

  document.querySelectorAll("#proc-table thead th").forEach((th) => {
    th.addEventListener("click", () => {
      const col = th.dataset.col;
      if (procSortCol === col) {
        procSortAsc = !procSortAsc;
      } else {
        procSortCol = col;
        procSortAsc = true;
      }
      renderProcs();
    });
  });

  setInterval(() => {
    if (procDirty) {
      renderProcs();
      procDirty = false;
    }
  }, PROCESS_RENDER_INTERVAL_MS);

  setInterval(() => {
    refreshProcessesFromApi();
  }, PROCESS_REFRESH_INTERVAL_MS);

  common.connectEventStream({
    onEvent: (ev) => {
      if (ev?.kind === "rich_proc_snapshot" || ev?.kind === "proc_snapshot") {
        processes.applyProcessSnapshot(procMap, ev);
        procDirty = true;
      }
    },
  });

  refreshProcessesFromApi();
  common.initResizableTables();
})();

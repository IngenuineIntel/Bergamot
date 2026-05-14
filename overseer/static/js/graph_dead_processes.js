"use strict";

(() => {
  const common = window.BergamotCommon;
  const processes = window.BergamotProcesses;
  // Debounce delay before reloading dead-process rows after relevant events.
  const DEAD_PROCESS_REFRESH_DELAY_MS = 600;
  // How often process snapshots are polled for hover-detail enrichment.
  const PROCESS_REFRESH_INTERVAL_MS = 2000;
  // Default page index for dead-processes pagination.
  const DEAD_PROCESS_DEFAULT_PAGE = 0;
  // Default number of dead-process rows per page.
  const DEAD_PROCESS_DEFAULT_PAGE_SIZE = 300;

  const body = document.getElementById("dead-processes-body");
  if (!body || !processes) return;

  const prevBtn = document.getElementById("dead-processes-prev");
  const nextBtn = document.getElementById("dead-processes-next");
  const pageInfo = document.getElementById("dead-processes-page-info");
  const pageSizeEl = document.getElementById("dead-processes-page-size");

  const procMap = processes.createProcessMap();
  const hover = processes.createProcessHoverController(procMap);
  const deadPaging = {
    page: DEAD_PROCESS_DEFAULT_PAGE,
    pageSize: DEAD_PROCESS_DEFAULT_PAGE_SIZE,
    hasMore: false,
  };

  let refreshTimer = null;

  function hasPagingControls() {
    return Boolean(prevBtn && nextBtn && pageInfo && pageSizeEl);
  }

  function updatePagingControls() {
    if (!hasPagingControls()) return;

    pageInfo.textContent = `Page ${deadPaging.page + 1}`;
    prevBtn.disabled = deadPaging.page <= 0;
    nextBtn.disabled = !deadPaging.hasMore;
    pageSizeEl.value = String(deadPaging.pageSize);
  }

  function deadProcessesUrl() {
    if (!hasPagingControls()) return "/api/dead-processes";

    const params = new URLSearchParams();
    params.set("limit", String(deadPaging.pageSize));
    params.set("offset", String(deadPaging.page * deadPaging.pageSize));
    return `/api/dead-processes?${params.toString()}`;
  }

  function renderRows(rows) {
    const fragment = document.createDocumentFragment();

    rows.forEach((row) => {
      const liveProc = procMap[row.pid] || {};
      const tr = document.createElement("tr");
      hover.bindRow(tr, row, "dead-processes");
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
      // Hover panel can still work with dead-process row values only.
    }
  }

  async function loadDeadProcessesSnapshot() {
    const rows = await fetch(deadProcessesUrl()).then((r) => r.json());
    const normalizedRows = Array.isArray(rows) ? rows : [];
    renderRows(normalizedRows);

    if (hasPagingControls()) {
      deadPaging.hasMore = normalizedRows.length >= deadPaging.pageSize;
      updatePagingControls();
    }
  }

  function scheduleRefresh() {
    if (refreshTimer) return;
    refreshTimer = setTimeout(() => {
      refreshTimer = null;
      loadDeadProcessesSnapshot().catch(() => {});
    }, DEAD_PROCESS_REFRESH_DELAY_MS);
  }

  function changePage(nextPage) {
    const safePage = Math.max(0, nextPage);
    if (safePage === deadPaging.page) return;

    deadPaging.page = safePage;
    updatePagingControls();
    loadDeadProcessesSnapshot().catch(() => {});
  }

  function changePageSize(nextPageSize) {
    const parsed = Number(nextPageSize);
    if (!Number.isFinite(parsed) || parsed <= 0) return;
    if (parsed === deadPaging.pageSize) return;

    deadPaging.pageSize = parsed;
    deadPaging.page = 0;
    updatePagingControls();
    loadDeadProcessesSnapshot().catch(() => {});
  }

  function initControls() {
    if (!hasPagingControls()) return;

    const initialPageSize = Number(pageSizeEl.value);
    if (Number.isFinite(initialPageSize) && initialPageSize > 0) {
      deadPaging.pageSize = initialPageSize;
    }

    prevBtn.addEventListener("click", () => {
      changePage(deadPaging.page - 1);
    });

    nextBtn.addEventListener("click", () => {
      if (!deadPaging.hasMore) return;
      changePage(deadPaging.page + 1);
    });

    pageSizeEl.addEventListener("change", () => {
      changePageSize(pageSizeEl.value);
    });

    updatePagingControls();
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

  initControls();
  Promise.all([loadProcesses(), loadDeadProcessesSnapshot()]).catch((err) => {
    console.warn("Dead-processes snapshot failed:", err);
  });

  setInterval(() => {
    loadProcesses();
  }, PROCESS_REFRESH_INTERVAL_MS);

  common.initResizableTables();
})();

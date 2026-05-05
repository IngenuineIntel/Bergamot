/* app.js — Over-Seer browser client
 *
 * Browser <-> Over-Seer interfaces:
 *   1) Initial snapshots over REST:
 *      /api/processes, /api/file_opens, /api/network, /api/stats
 *   2) Live stream over SSE:
 *      /api/stream with event types: event, stats, ping
 *
 * Payload schemas:
 *   Raw syscall events: {ts_s, ts_ms, pid, ppid, uid, type, subtype, comm, arg}
 *   Process snapshots: {kind: "proc_snapshot", ts_s, ts_ms, processes: [...]}
 */

"use strict";

const SPARKLINE_POINTS = 60;
const SPARKLINE_MAX_Y  = 300;
const SPARKLINE_MIN_Y  = 10;

const MAX_FEED_ROWS = 300;
const COLUMN_WIDTHS_KEY_PREFIX = "bergamot:column-widths:";
const MIN_COLUMN_WIDTH_PX = 64;

const ui = {
  statEps: document.getElementById("stat-eps"),
  statAgents: document.getElementById("stat-agents"),
  statUptime: document.getElementById("stat-uptime"),
  epsCanvas: document.getElementById("eps-chart"),
  procTable: document.getElementById("proc-table"),
  procBody: document.getElementById("proc-body"),
  openBody: document.getElementById("open-body"),
  netBody: document.getElementById("net-body"),
  syscallsBody: document.getElementById("syscalls-body"),
  forkBody: document.getElementById("fork-body"),
  forkExecBody: document.getElementById("fork-exec-body"),
  lifecycleBody: document.getElementById("lifecycle-body"),
  deadProcessesBody: document.getElementById("dead-processes-body"),
};

const hasStats = Boolean(ui.statEps || ui.statAgents || ui.statUptime);
const hasEps = Boolean(ui.epsCanvas && typeof window.Chart !== "undefined");
const hasProcTable = Boolean(ui.procBody);
const hasOpenFeed = Boolean(ui.openBody);
const hasNetworkFeed = Boolean(ui.netBody);
const hasSyscallsFeed = Boolean(ui.syscallsBody);
const hasForkFeed = Boolean(ui.forkBody);
const hasForkExecFeed = Boolean(ui.forkExecBody);
const hasLifecycleFeed = Boolean(ui.lifecycleBody);
const hasDeadProcessesFeed = Boolean(ui.deadProcessesBody);

let lifecycleRefreshTimer = null;
let deadProcessesRefreshTimer = null;

const PROCESS_PANEL_CURSOR_OFFSET_PX = 18;
const PROCESS_PANEL_VIEWPORT_PADDING_PX = 12;

const processHoverState = {
  panelEl: null,
  activeRowKey: null,
  activeTableKind: null,
  mouseX: 0,
  mouseY: 0,
  rafId: null,
};

let epsData = null;
let epsChart = null;

if (hasEps) {
  epsData = Array(SPARKLINE_POINTS).fill(0);
  epsChart = new Chart(ui.epsCanvas, {
    type: "line",
    data: {
      labels: Array(SPARKLINE_POINTS).fill(""),
      datasets: [{
        data: epsData,
        borderColor: "#58a6ff",
        backgroundColor: "rgba(88,166,255,0.15)",
        borderWidth: 2,
        pointRadius: 0,
        tension: 0.3,
        fill: true,
      }],
    },
    options: {
      animation: false,
      responsive: true,
      plugins: { legend: { display: false }, tooltip: { enabled: false } },
      scales: {
        x: { display: false },
        y: {
          min: 0,
          max: SPARKLINE_MAX_Y,
          ticks: { color: "#8b949e", maxTicksLimit: 4 },
          grid: { color: "#30363d" },
        },
      },
    },
  });
}

function pushEps(value) {
  if (!epsData || !epsChart) return;
  epsData.push(value);
  epsData.shift();

  // Scale y-axis to the recent peak so current values are never clipped.
  const peak = Math.max(...epsData, 1);
  const targetMax = Math.max(SPARKLINE_MIN_Y, niceCeil(peak * 1.15));
  if (epsChart.options.scales?.y?.max !== targetMax) {
    epsChart.options.scales.y.max = targetMax;
  }

  epsChart.update("none");
}

function fmtUptime(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return `${h}h ${m}m ${s}s`;
}

function fmtEventTs(ts_s, ts_ms) {
  const sec = Number(ts_s ?? 0);
  const ms = Number(ts_ms ?? 0);
  return `${sec}.${String(ms).padStart(3, "0")}`;
}

function applyStats(stats) {
  const eps = Number(stats.events_per_sec || 0);
  if (ui.statEps) ui.statEps.textContent = eps.toFixed(1);
  if (ui.statAgents) ui.statAgents.textContent = String(stats.agent_count ?? 0);
  if (ui.statUptime) ui.statUptime.textContent = fmtUptime(Number(stats.uptime_s || 0));
  if (hasEps) pushEps(eps);
}

// --- Process table -----------------------------------------------------------

let procSortCol = "pid";
let procSortAsc = true;
const procMap = {}; // pid -> row data, updated from snapshots

if (ui.procTable) {
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
}

function applyProcessSnapshot(snapshot) {
  const rows = Array.isArray(snapshot?.processes) ? snapshot.processes : [];

  Object.keys(procMap).forEach((pid) => {
    delete procMap[pid];
  });

  rows.forEach((row) => {
    const pid = Number(row.pid);
    if (!Number.isFinite(pid) || pid <= 0) return;

    procMap[pid] = {
      pid,
      ppid: Number(row.ppid ?? 0),
      uid: Number(row.uid ?? 0),
      comm: row.comm ?? "",
      threads: Number(row.threads ?? 0),
      last_seen_s: Number(snapshot.ts_s ?? 0),
      last_seen_ms: Number(snapshot.ts_ms ?? 0),
    };
  });

  procDirty = true;
}

function renderProcs() {
  if (!ui.procBody) return;

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
      <td>${esc(p.comm)}</td>
      <td>${p.threads ?? 0}</td>
      <td>${fmtEventTs(p.last_seen_s, p.last_seen_ms)}</td>
    `;
    fragment.appendChild(tr);
  });

  ui.procBody.replaceChildren(fragment);
}

let procDirty = false;
setInterval(() => {
  if (procDirty) {
    renderProcs();
    procDirty = false;
  }
}, 1000);

// --- Feed tables -------------------------------------------------------------

function prependFeedRow(tbodyId, ev) {
  const tbody = tbodyId === "open-body" ? ui.openBody : ui.netBody;
  if (!tbody) return;

  const tr = document.createElement("tr");
  tr.innerHTML = `
    <td>${fmtEventTs(ev.ts_s, ev.ts_ms)}</td>
    <td>${ev.pid}</td>
    <td>${esc(ev.comm)}</td>
    <td class="arg-cell">${esc(ev.arg)}</td>
  `;
  tbody.insertBefore(tr, tbody.firstChild);

  while (tbody.rows.length > MAX_FEED_ROWS) {
    tbody.deleteRow(tbody.rows.length - 1);
  }
}

function packetType(ev) {
  if (ev?.kind === "proc_snapshot") return "proc_snapshot";
  if (typeof ev?.type === "string" && ev.type) return ev.type;
  if (typeof ev?.kind === "string" && ev.kind) return ev.kind;
  return "unknown";
}

function packetArg1(ev) {
  if (ev?.arg1 != null) return ev.arg1;
  if (ev?.arg != null) return ev.arg;
  if (ev?.kind === "proc_snapshot" && Array.isArray(ev?.processes)) {
    return `processes=${ev.processes.length}`;
  }
  return "";
}

function packetArg2(ev) {
  if (ev?.arg2 != null) return ev.arg2;
  return "";
}

function prependEventRow(ev) {
  if (!ui.syscallsBody || !ev || typeof ev !== "object") return;

  const tr = document.createElement("tr");
  tr.innerHTML = `
    <td>${fmtEventTs(ev.ts_s, ev.ts_ms)}</td>
    <td>${esc(ev.pid ?? "")}</td>
    <td>${esc(ev.ppid ?? "")}</td>
    <td>${esc(ev.uid ?? "")}</td>
    <td>${esc(packetType(ev))}</td>
    <td>${esc(ev.comm ?? "")}</td>
    <td class="arg-cell">${esc(packetArg1(ev))}</td>
    <td class="arg-cell">${esc(packetArg2(ev))}</td>
  `;
  ui.syscallsBody.insertBefore(tr, ui.syscallsBody.firstChild);

  while (ui.syscallsBody.rows.length > MAX_FEED_ROWS) {
    ui.syscallsBody.deleteRow(ui.syscallsBody.rows.length - 1);
  }
}

function prependForkRow(ev) {
  if (!ui.forkBody || !ev || typeof ev !== "object") return;

  const tr = document.createElement("tr");
  tr.innerHTML = `
    <td>${fmtEventTs(ev.ts_s, ev.ts_ms)}</td>
    <td>${esc(ev.pid ?? "")}</td>
    <td>${esc(ev.ppid ?? "")}</td>
    <td>${esc(ev.uid ?? "")}</td>
    <td>${esc(ev.comm ?? "")}</td>
    <td class="arg-cell">${esc(ev.arg ?? "")}</td>
  `;
  ui.forkBody.insertBefore(tr, ui.forkBody.firstChild);

  while (ui.forkBody.rows.length > MAX_FEED_ROWS) {
    ui.forkBody.deleteRow(ui.forkBody.rows.length - 1);
  }
}

function prependForkExecRow(ev) {
  if (!ui.forkExecBody || !ev || typeof ev !== "object") return;

  const tr = document.createElement("tr");
  tr.innerHTML = `
    <td>${fmtEventTs(ev.ts_s, ev.ts_ms)}</td>
    <td>${esc(ev.type ?? "")}</td>
    <td>${esc(ev.pid ?? "")}</td>
    <td>${esc(ev.ppid ?? "")}</td>
    <td>${esc(ev.uid ?? "")}</td>
    <td>${esc(ev.comm ?? "")}</td>
    <td class="arg-cell">${esc(ev.arg ?? "")}</td>
  `;
  ui.forkExecBody.insertBefore(tr, ui.forkExecBody.firstChild);

  while (ui.forkExecBody.rows.length > MAX_FEED_ROWS) {
    ui.forkExecBody.deleteRow(ui.forkExecBody.rows.length - 1);
  }
}

function processRowKey(row) {
  return [
    String(row.pid ?? ""),
    String(row.start_ts_s ?? ""),
    String(row.start_ts_ms ?? ""),
    String(row.last_ts_s ?? ""),
    String(row.last_ts_ms ?? ""),
    String(row.comm ?? ""),
  ].join("|");
}

function boolToYesNo(value) {
  return value ? "yes" : "no";
}

function processDetailsMarkup(row) {
  const details = [
    ["Start", fmtEventTs(row.start_ts_s, row.start_ts_ms)],
    ["Last", fmtEventTs(row.last_ts_s, row.last_ts_ms)],
    ["PID", row.pid ?? ""],
    ["PPID", row.ppid ?? ""],
    ["UID", row.uid ?? ""],
    ["Comm", row.comm ?? ""],
    ["Exec", row.exec_arg ?? ""],
    ["Running", boolToYesNo(row.running)],
    ["Opens", row.open_count ?? 0],
    ["Connects", row.connect_count ?? 0],
    ["First Open", row.first_open ?? ""],
    ["First Connect", row.first_connect ?? ""],
  ];

  const lines = details.map(([label, value]) => `
    <div class="process-hover-details__label">${esc(label)}</div>
    <div class="process-hover-details__value">${esc(value)}</div>
  `).join("");

  return `
    <div class="process-hover-details__title">Process Details</div>
    <div class="process-hover-details__grid">${lines}</div>
  `;
}

function ensureProcessHoverPanel() {
  if (processHoverState.panelEl) return processHoverState.panelEl;

  const panel = document.createElement("aside");
  panel.className = "process-hover-details";
  panel.setAttribute("aria-hidden", "true");
  document.body.appendChild(panel);

  processHoverState.panelEl = panel;
  return panel;
}

function scheduleProcessPanelPositionUpdate() {
  if (processHoverState.rafId != null) return;

  processHoverState.rafId = window.requestAnimationFrame(() => {
    processHoverState.rafId = null;
    updateProcessPanelPosition();
  });
}

function updateProcessPanelPosition() {
  const panel = processHoverState.panelEl;
  if (!panel || !panel.classList.contains("is-visible")) return;

  const panelWidth = panel.offsetWidth;
  const panelHeight = panel.offsetHeight;
  const maxX = Math.max(
    PROCESS_PANEL_VIEWPORT_PADDING_PX,
    window.innerWidth - panelWidth - PROCESS_PANEL_VIEWPORT_PADDING_PX
  );
  const maxY = Math.max(
    PROCESS_PANEL_VIEWPORT_PADDING_PX,
    window.innerHeight - panelHeight - PROCESS_PANEL_VIEWPORT_PADDING_PX
  );

  let x = processHoverState.mouseX + PROCESS_PANEL_CURSOR_OFFSET_PX;
  let y = processHoverState.mouseY + PROCESS_PANEL_CURSOR_OFFSET_PX;

  if (x > maxX) {
    x = processHoverState.mouseX - panelWidth - PROCESS_PANEL_CURSOR_OFFSET_PX;
  }
  if (y > maxY) {
    y = processHoverState.mouseY - panelHeight - PROCESS_PANEL_CURSOR_OFFSET_PX;
  }

  x = Math.max(PROCESS_PANEL_VIEWPORT_PADDING_PX, Math.min(x, maxX));
  y = Math.max(PROCESS_PANEL_VIEWPORT_PADDING_PX, Math.min(y, maxY));

  panel.style.left = `${Math.round(x)}px`;
  panel.style.top = `${Math.round(y)}px`;
}

function hideProcessPanel() {
  const panel = processHoverState.panelEl;
  if (!panel) return;

  panel.classList.remove("is-visible");
  panel.setAttribute("aria-hidden", "true");
  processHoverState.activeRowKey = null;
  processHoverState.activeTableKind = null;
}

function showProcessPanel(row, tableKind) {
  const panel = ensureProcessHoverPanel();

  panel.innerHTML = processDetailsMarkup(row);
  panel.classList.add("is-visible");
  panel.setAttribute("aria-hidden", "false");

  processHoverState.activeRowKey = processRowKey(row);
  processHoverState.activeTableKind = tableKind;

  scheduleProcessPanelPositionUpdate();
}

function bindProcessHoverRow(tr, row, tableKind) {
  tr.classList.add("process-hover-row");
  tr.dataset.processHover = "1";
  tr.dataset.processHoverKey = processRowKey(row);
  tr.__processHoverRow = row;
  tr.__processHoverTableKind = tableKind;

  tr.addEventListener("mouseenter", (event) => {
    processHoverState.mouseX = event.clientX;
    processHoverState.mouseY = event.clientY;
    showProcessPanel(row, tableKind);
  });

  tr.addEventListener("mousemove", (event) => {
    processHoverState.mouseX = event.clientX;
    processHoverState.mouseY = event.clientY;
    if (!processHoverState.activeRowKey) {
      showProcessPanel(row, tableKind);
      return;
    }
    scheduleProcessPanelPositionUpdate();
  });

  tr.addEventListener("mouseleave", () => {
    hideProcessPanel();
  });
}

function syncProcessPanelAfterRowsRender() {
  if (!processHoverState.activeRowKey) return;

  const el = document.elementFromPoint(processHoverState.mouseX, processHoverState.mouseY);
  const rowEl = el?.closest?.("tr[data-process-hover='1']");
  if (!rowEl || !rowEl.__processHoverRow || !rowEl.__processHoverTableKind) {
    hideProcessPanel();
    return;
  }

  const nextKey = rowEl.dataset.processHoverKey || "";
  if (
    nextKey !== processHoverState.activeRowKey
    || rowEl.__processHoverTableKind !== processHoverState.activeTableKind
  ) {
    showProcessPanel(rowEl.__processHoverRow, rowEl.__processHoverTableKind);
  } else {
    scheduleProcessPanelPositionUpdate();
  }
}

function renderLifecycleRows(rows) {
  if (!ui.lifecycleBody) return;

  const fragment = document.createDocumentFragment();
  rows.forEach((row) => {
    const tr = document.createElement("tr");
    bindProcessHoverRow(tr, row, "lifecycle");
    tr.innerHTML = `
      <td>${fmtEventTs(row.start_ts_s, row.start_ts_ms)}</td>
      <td>${fmtEventTs(row.last_ts_s, row.last_ts_ms)}</td>
      <td>${esc(row.pid ?? "")}</td>
      <td>${esc(row.ppid ?? "")}</td>
      <td>${esc(row.uid ?? "")}</td>
      <td>${esc(row.comm ?? "")}</td>
      <td class="arg-cell">${esc(row.exec_arg ?? "")}</td>
      <td>${row.running ? "yes" : "no"}</td>
      <td>${esc(row.open_count ?? 0)}</td>
      <td>${esc(row.connect_count ?? 0)}</td>
      <td class="arg-cell">${esc(row.first_open ?? "")}</td>
      <td class="arg-cell">${esc(row.first_connect ?? "")}</td>
    `;
    fragment.appendChild(tr);
  });

  ui.lifecycleBody.replaceChildren(fragment);
  syncProcessPanelAfterRowsRender();
}

function renderDeadProcessesRows(rows) {
  if (!ui.deadProcessesBody) return;

  const fragment = document.createDocumentFragment();
  rows.forEach((row) => {
    const tr = document.createElement("tr");
    bindProcessHoverRow(tr, row, "dead-processes");
    tr.innerHTML = `
      <td>${fmtEventTs(row.start_ts_s, row.start_ts_ms)}</td>
      <td>${fmtEventTs(row.last_ts_s, row.last_ts_ms)}</td>
      <td>${esc(row.pid ?? "")}</td>
      <td>${esc(row.ppid ?? "")}</td>
      <td>${esc(row.uid ?? "")}</td>
      <td>${esc(row.comm ?? "")}</td>
      <td class="arg-cell">${esc(row.exec_arg ?? "")}</td>
      <td>${row.running ? "yes" : "no"}</td>
      <td>${esc(row.open_count ?? 0)}</td>
      <td>${esc(row.connect_count ?? 0)}</td>
      <td class="arg-cell">${esc(row.first_open ?? "")}</td>
      <td class="arg-cell">${esc(row.first_connect ?? "")}</td>
    `;
    fragment.appendChild(tr);
  });

  ui.deadProcessesBody.replaceChildren(fragment);
  syncProcessPanelAfterRowsRender();
}

async function loadLifecycleSnapshot() {
  if (!hasLifecycleFeed) return;

  const rows = await fetch("/api/lifecycle")
    .then((r) => r.json());
  renderLifecycleRows(Array.isArray(rows) ? rows : []);
}

function scheduleLifecycleRefresh() {
  if (!hasLifecycleFeed) return;
  if (lifecycleRefreshTimer) return;

  lifecycleRefreshTimer = setTimeout(() => {
    lifecycleRefreshTimer = null;
    loadLifecycleSnapshot().catch(() => {});
  }, 600);
}

async function loadDeadProcessesSnapshot() {
  if (!hasDeadProcessesFeed) return;

  const rows = await fetch("/api/dead-processes")
    .then((r) => r.json());
  renderDeadProcessesRows(Array.isArray(rows) ? rows : []);
}

function scheduleDeadProcessesRefresh() {
  if (!hasDeadProcessesFeed) return;
  if (deadProcessesRefreshTimer) return;

  deadProcessesRefreshTimer = setTimeout(() => {
    deadProcessesRefreshTimer = null;
    loadDeadProcessesSnapshot().catch(() => {});
  }, 600);
}

function ingestEvent(ev) {
  if (hasProcTable && ev?.kind === "proc_snapshot") {
    applyProcessSnapshot(ev);
    if (hasSyscallsFeed) prependEventRow(ev);
    return;
  }

  if (hasOpenFeed && ev.type === "open") prependFeedRow("open-body", ev);
  if (hasNetworkFeed && ev.type === "connect") prependFeedRow("net-body", ev);
  if (hasForkFeed && ev.type === "fork") prependForkRow(ev);
  if (hasForkExecFeed && (ev.type === "fork" || ev.type === "execve")) prependForkExecRow(ev);
  if (hasLifecycleFeed && (ev.type === "fork" || ev.type === "execve" || ev.type === "open" || ev.type === "connect" || ev.kind === "proc_snapshot")) {
    scheduleLifecycleRefresh();
  }
  if (hasDeadProcessesFeed && (ev.type === "fork" || ev.type === "execve" || ev.type === "open" || ev.type === "connect" || ev.kind === "proc_snapshot")) {
    scheduleDeadProcessesRefresh();
  }
  if (hasSyscallsFeed) prependEventRow(ev);
}

// --- REST snapshot bootstrap -------------------------------------------------

async function loadSnapshot() {
  const tasks = [];

  if (hasProcTable) {
    tasks.push(
      fetch("/api/processes")
        .then((r) => r.json())
        .then((procs) => {
          procs.forEach((p) => {
            procMap[p.pid] = p;
          });
          procDirty = true;
        })
    );
  }

  if (hasOpenFeed) {
    tasks.push(
      fetch("/api/file_opens")
        .then((r) => r.json())
        .then((opens) => {
          [...opens].reverse().forEach((ev) => prependFeedRow("open-body", ev));
        })
    );
  }

  if (hasNetworkFeed) {
    tasks.push(
      fetch("/api/network")
        .then((r) => r.json())
        .then((nets) => {
          [...nets].reverse().forEach((ev) => prependFeedRow("net-body", ev));
        })
    );
  }

  if (hasSyscallsFeed) {
    tasks.push(
      fetch("/api/events")
        .then((r) => r.json())
        .then((events) => {
          [...events].reverse().forEach((ev) => prependEventRow(ev));
        })
    );
  }

  if (hasForkFeed) {
    tasks.push(
      fetch("/api/fork")
        .then((r) => r.json())
        .then((items) => {
          [...items].reverse().forEach((ev) => prependForkRow(ev));
        })
    );
  }

  if (hasForkExecFeed) {
    tasks.push(
      fetch("/api/fork-exec")
        .then((r) => r.json())
        .then((items) => {
          [...items].reverse().forEach((ev) => prependForkExecRow(ev));
        })
    );
  }

  if (hasLifecycleFeed) {
    tasks.push(loadLifecycleSnapshot());
  }

  if (hasDeadProcessesFeed) {
    tasks.push(loadDeadProcessesSnapshot());
  }

  if (hasEps || hasStats) {
    tasks.push(
      fetch("/api/stats")
        .then((r) => r.json())
        .then((stats) => {
          applyStats(stats);
        })
    );
  }

  await Promise.all(tasks);
}

// --- SSE live updates --------------------------------------------------------

function connectSSE() {
  if (!(hasEps || hasStats || hasProcTable || hasOpenFeed || hasNetworkFeed || hasSyscallsFeed || hasForkFeed || hasForkExecFeed || hasLifecycleFeed || hasDeadProcessesFeed)) {
    return;
  }

  const es = new EventSource("/api/stream");

  if (hasProcTable || hasOpenFeed || hasNetworkFeed || hasSyscallsFeed || hasForkFeed || hasForkExecFeed || hasLifecycleFeed || hasDeadProcessesFeed) {
    es.addEventListener("event", (e) => {
      try {
        ingestEvent(JSON.parse(e.data));
      } catch (_) {}
    });
  }

  if (hasEps || hasStats) {
    es.addEventListener("stats", (e) => {
      try {
        applyStats(JSON.parse(e.data));
      } catch (_) {}
    });
  }

  es.addEventListener("ping", () => {
    // Keepalive frame, no UI update required.
  });

  es.onerror = () => {
    // Native EventSource auto-reconnect handles recovery.
    console.warn("SSE disconnected; browser will auto-reconnect.");
  };
}

// --- Helpers -----------------------------------------------------------------

function esc(str) {
  return String(str ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function niceCeil(value) {
  if (!Number.isFinite(value) || value <= 0) return SPARKLINE_MIN_Y;
  const exponent = Math.floor(Math.log10(value));
  const unit = Math.pow(10, exponent);
  return Math.ceil(value / unit) * unit;
}

function columnWidthsStorageKey(tableIndex) {
  return `${COLUMN_WIDTHS_KEY_PREFIX}${window.location.pathname}:table-${tableIndex}`;
}

function loadSavedColumnWidths(key) {
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : null;
  } catch (_) {
    return null;
  }
}

function saveColumnWidths(key, widths) {
  try {
    window.localStorage.setItem(key, JSON.stringify(widths));
  } catch (_) {
    // Ignore storage failures.
  }
}

function applySavedWidths(headers, widths) {
  if (!Array.isArray(widths)) return;
  headers.forEach((th, idx) => {
    if (idx === headers.length - 1) return; // last column always fills remaining space
    const width = Number(widths[idx]);
    if (!Number.isFinite(width) || width < MIN_COLUMN_WIDTH_PX) return;
    th.style.width = `${Math.round(width)}px`;
    th.style.minWidth = `${MIN_COLUMN_WIDTH_PX}px`;
  });
}

function freezeHeaderWidths(table, headers) {
  const widths = headers.map((h) => Math.round(h.getBoundingClientRect().width));
  widths.forEach((width, idx) => {
    headers[idx].style.width = `${width}px`;
    headers[idx].style.minWidth = `${MIN_COLUMN_WIDTH_PX}px`;
  });

  const totalWidth = widths.reduce((sum, width) => sum + width, 0);
  table.style.width = `${totalWidth}px`;
  table.style.minWidth = `${totalWidth}px`;

  return widths;
}

function initResizableTables() {
  const tables = Array.from(document.querySelectorAll(".table-wrap table"));

  tables.forEach((table, tableIndex) => {
    const headRow = table.querySelector("thead tr");
    if (!headRow) return;

    const headers = Array.from(headRow.querySelectorAll("th"));
    if (headers.length < 2) return;

    table.classList.add("resizable-table");
    const storageKey = columnWidthsStorageKey(tableIndex);
    applySavedWidths(headers, loadSavedColumnWidths(storageKey));

    headers.forEach((th, colIdx) => {
      if (colIdx === headers.length - 1) return;

      const rightHeader = headers[colIdx + 1];
      if (!rightHeader) return;

      const handle = document.createElement("span");
      handle.className = "col-resize-handle";
      handle.setAttribute("aria-hidden", "true");
      th.appendChild(handle);

      handle.addEventListener("mousedown", (downEvent) => {
        downEvent.preventDefault();
        downEvent.stopPropagation();

        freezeHeaderWidths(table, headers);

        const startX = downEvent.clientX;
        const startWidth = th.getBoundingClientRect().width;
        const rightStartWidth = rightHeader.getBoundingClientRect().width;
        let didResize = false;

        th.classList.add("is-resizing");
        rightHeader.classList.add("is-resizing");
        document.body.classList.add("is-resizing-cols");

        const onMouseMove = (moveEvent) => {
          const delta = moveEvent.clientX - startX;
          const nextLeftWidth = Math.max(
            MIN_COLUMN_WIDTH_PX,
            Math.min(Math.round(startWidth + delta), Math.round(startWidth + rightStartWidth - MIN_COLUMN_WIDTH_PX))
          );
          const nextRightWidth = Math.max(
            MIN_COLUMN_WIDTH_PX,
            Math.round(startWidth + rightStartWidth - nextLeftWidth)
          );

          if (Math.abs(delta) >= 2) didResize = true;

          th.style.width = `${nextLeftWidth}px`;
          th.style.minWidth = `${MIN_COLUMN_WIDTH_PX}px`;
          rightHeader.style.width = `${nextRightWidth}px`;
          rightHeader.style.minWidth = `${MIN_COLUMN_WIDTH_PX}px`;
        };

        const onMouseUp = () => {
          document.removeEventListener("mousemove", onMouseMove);
          document.removeEventListener("mouseup", onMouseUp);
          th.classList.remove("is-resizing");
          rightHeader.classList.remove("is-resizing");
          document.body.classList.remove("is-resizing-cols");

          if (!didResize) return;
          // Exclude the last column — its width is always auto-filled.
          const widths = headers.slice(0, -1).map((h) => Math.round(h.getBoundingClientRect().width));
          saveColumnWidths(storageKey, widths);
        };

        document.addEventListener("mousemove", onMouseMove);
        document.addEventListener("mouseup", onMouseUp);
      });
    });
  });
}

// --- Boot --------------------------------------------------------------------

initResizableTables();

window.addEventListener("resize", () => {
  scheduleProcessPanelPositionUpdate();
});

if (hasEps || hasStats || hasProcTable || hasOpenFeed || hasNetworkFeed || hasSyscallsFeed || hasForkFeed || hasForkExecFeed || hasLifecycleFeed || hasDeadProcessesFeed) {
  loadSnapshot()
    .then(connectSSE)
    .catch((err) => {
      console.warn("Initial snapshot failed:", err);
      connectSSE();
    });
}

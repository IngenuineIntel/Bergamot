/* app.js — Over-Seer browser client
 *
 * Browser <-> Over-Seer interfaces:
 *   1) Initial snapshots over REST:
 *      /api/processes, /api/file_opens, /api/network, /api/stats
 *   2) Live stream over SSE:
 *      /api/stream with event types: event, stats, ping
 *
 * Payload schema mirrors Under-Seer output:
 *   {ts, pid, ppid, uid, type, comm, arg}
 */

"use strict";

const SPARKLINE_POINTS = 60;
const MAX_FEED_ROWS = 100;

// --- Sparkline ---------------------------------------------------------------

const epsData = Array(SPARKLINE_POINTS).fill(0);
const epsChart = new Chart(document.getElementById("eps-chart"), {
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
        ticks: { color: "#8b949e", maxTicksLimit: 4 },
        grid: { color: "#30363d" },
      },
    },
  },
});

function pushEps(value) {
  epsData.push(value);
  epsData.shift();
  epsChart.update("none");
}

function fmtUptime(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return `${h}h ${m}m ${s}s`;
}

function applyStats(stats) {
  const eps = Number(stats.events_per_sec || 0);
  document.getElementById("stat-eps").textContent = eps.toFixed(1);
  document.getElementById("stat-agents").textContent = String(stats.agent_count ?? 0);
  document.getElementById("stat-uptime").textContent = fmtUptime(Number(stats.uptime_s || 0));
  pushEps(eps);
}

// --- Process table -----------------------------------------------------------

let procSortCol = "pid";
let procSortAsc = true;
const procMap = {}; // pid -> row data, updated from snapshots + SSE events

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

function updateProcFromEvent(ev) {
  procMap[ev.pid] = {
    pid: ev.pid,
    ppid: ev.ppid,
    uid: ev.uid,
    comm: ev.comm,
    last_seen: ev.ts,
  };
}

function renderProcs() {
  const rows = Object.values(procMap);
  rows.sort((a, b) => {
    const av = a[procSortCol] ?? "";
    const bv = b[procSortCol] ?? "";
    if (av < bv) return procSortAsc ? -1 : 1;
    if (av > bv) return procSortAsc ? 1 : -1;
    return 0;
  });

  const tbody = document.getElementById("proc-body");
  const fragment = document.createDocumentFragment();

  rows.forEach((p) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${p.pid}</td>
      <td>${p.ppid}</td>
      <td>${p.uid}</td>
      <td>${esc(p.comm)}</td>
      <td>${p.last_seen}</td>
    `;
    fragment.appendChild(tr);
  });

  tbody.replaceChildren(fragment);
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
  const tbody = document.getElementById(tbodyId);
  if (!tbody) return;

  const tr = document.createElement("tr");
  tr.innerHTML = `
    <td>${ev.ts}</td>
    <td>${ev.pid}</td>
    <td>${esc(ev.comm)}</td>
    <td class="arg-cell">${esc(ev.arg)}</td>
  `;
  tbody.insertBefore(tr, tbody.firstChild);

  while (tbody.rows.length > MAX_FEED_ROWS) {
    tbody.deleteRow(tbody.rows.length - 1);
  }
}

function ingestEvent(ev) {
  updateProcFromEvent(ev);
  procDirty = true;

  if (ev.type === "open") prependFeedRow("open-body", ev);
  if (ev.type === "connect") prependFeedRow("net-body", ev);
}

// --- REST snapshot bootstrap -------------------------------------------------

async function loadSnapshot() {
  const [procs, opens, nets, stats] = await Promise.all([
    fetch("/api/processes").then((r) => r.json()),
    fetch("/api/file_opens").then((r) => r.json()),
    fetch("/api/network").then((r) => r.json()),
    fetch("/api/stats").then((r) => r.json()),
  ]);

  procs.forEach((p) => {
    procMap[p.pid] = p;
  });
  renderProcs();

  // Insert oldest-first so newest ends up visually on top.
  [...opens].reverse().forEach((ev) => prependFeedRow("open-body", ev));
  [...nets].reverse().forEach((ev) => prependFeedRow("net-body", ev));
  applyStats(stats);
}

// --- SSE live updates --------------------------------------------------------

function connectSSE() {
  const es = new EventSource("/api/stream");

  es.addEventListener("event", (e) => {
    try {
      ingestEvent(JSON.parse(e.data));
    } catch (_) {}
  });

  es.addEventListener("stats", (e) => {
    try {
      applyStats(JSON.parse(e.data));
    } catch (_) {}
  });

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

// --- Boot --------------------------------------------------------------------

loadSnapshot()
  .then(connectSSE)
  .catch((err) => {
    console.warn("Initial snapshot failed:", err);
    connectSSE();
  });

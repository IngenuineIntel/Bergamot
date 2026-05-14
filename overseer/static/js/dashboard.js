"use strict";

(() => {
  // How often the dashboard uptime text is refreshed.
  const UPTIME_REFRESH_INTERVAL_MS = 1000;

  const statUptime = document.getElementById("stat-uptime");
  if (!statUptime) return;

  function uptimeStringify(uptime) {
    const secs = uptime % 60;
    const mins = Math.floor(uptime / 60);
    const hrs = Math.floor(uptime / 3600);
    return `${hrs}:${mins}:${secs}`;
  }

  async function renderUptime() {
    const req = await fetch("/api/uptime");
    const j = await req.json();
    const uptime = Number(j.uptime ?? 0);
    if (uptime > 0) {
      return `LIVE for ${uptimeStringify(uptime)}`;
    }
    return "No Connections";
  }

  async function applyUptime() {
    try {
      statUptime.textContent = await renderUptime();
    } catch (_) {
      // Keep previous uptime text when request fails.
    }
  }

  applyUptime();
  setInterval(() => {
    applyUptime();
  }, UPTIME_REFRESH_INTERVAL_MS);
})();

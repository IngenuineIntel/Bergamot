"use strict";

(() => {
  const common = window.BergamotCommon;
  // Number of points shown in the rolling EPS chart.
  const CHART_POINTS = 60;
  // Initial upper bound for the Y-axis before auto-scaling.
  const CHART_INITIAL_MAX_Y = 300;
  // Smallest allowed Y-axis max when auto-scaling.
  const CHART_MIN_MAX_Y = 10;
  // How often EPS is polled from the API.
  const EPS_REFRESH_INTERVAL_MS = 1000;

  const canvas = document.getElementById("eps-chart");
  const hasChart = Boolean(canvas && typeof window.Chart !== "undefined");
  if (!hasChart) return;

  const epsData = Array(CHART_POINTS).fill(0);

  const epsChart = new Chart(canvas, {
    type: "line",
    data: {
      labels: Array(CHART_POINTS).fill(""),
      datasets: [
        {
          data: epsData,
          borderColor: "#58a6ff",
          backgroundColor: "rgba(88,166,255,0.15)",
          borderWidth: 2,
          pointRadius: 0,
          tension: 0.3,
          fill: true,
        },
      ],
    },
    options: {
      animation: false,
      responsive: true,
      plugins: { legend: { display: false }, tooltip: { enabled: false } },
      scales: {
        x: { display: false },
        y: {
          min: 0,
          max: CHART_INITIAL_MAX_Y,
          ticks: { color: "#8b949e", maxTicksLimit: 4 },
          grid: { color: "#30363d" },
        },
      },
    },
  });

  function pushEps(value) {
    epsData.push(value);
    epsData.shift();

    const peak = Math.max(...epsData, 1);
    const targetMax = Math.max(CHART_MIN_MAX_Y, common.niceCeil(peak * 1.15));
    if (epsChart.options.scales?.y?.max !== targetMax) {
      epsChart.options.scales.y.max = targetMax;
    }

    epsChart.update("none");
  }

  async function renderEPS() {
    const req = await fetch("/api/eps");
    const j = await req.json();
    return Number(j.eps ?? 0);
  }

  async function applyStats() {
    try {
      const eps = await renderEPS();
      pushEps(eps);
    } catch (_) {
      // Keep existing chart values when request fails.
    }
  }

  applyStats();
  setInterval(() => {
    applyStats();
  }, EPS_REFRESH_INTERVAL_MS);
})();

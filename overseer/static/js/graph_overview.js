"use strict";

(() => {
  // Delay before retrying overview fetch when data is not yet available.
  const OVERVIEW_RETRY_DELAY_MS = 3000;

  const uiGrid = document.getElementById("overview-grid");
  if (!uiGrid) return;

  function formatOverviewValue(key, value) {
    if (key === "ram_gbs") {
      return `${value} GB`;
    }
    return String(value ?? "");
  }

  function getOverviewEntries(overview) {
    const fieldOrder = [
      ["hostname", "Hostname"],
      ["kernelver", "Kernel"],
      ["distro", "Distro"],
      ["ipaddr", "IP Address"],
      ["macaddr", "MAC Address"],
      ["processor", "Processor"],
      ["processor_vend", "Processor Vendor"],
      ["ram_gbs", "RAM"],
    ];

    return fieldOrder
      .map(([key, label]) => [label, key, overview?.[key]])
      .filter(([, , value]) => value !== undefined && value !== null && value !== "" && value !== 0);
  }

  function renderOverviewGrid(overview) {
    const entries = getOverviewEntries(overview);
    const fragment = document.createDocumentFragment();

    entries.forEach(([label, key, value]) => {
      const labelEl = document.createElement("div");
      labelEl.className = "overview-grid__label";
      labelEl.textContent = label;

      const valueEl = document.createElement("div");
      valueEl.className = "overview-grid__value";
      valueEl.textContent = formatOverviewValue(key, value);

      fragment.appendChild(labelEl);
      fragment.appendChild(valueEl);
    });

    uiGrid.replaceChildren(fragment);
  }

  async function loadOverview() {
    const response = await fetch("/api/overview");
    if (response.status === 404) {
      return null;
    }
    if (!response.ok) {
      throw new Error(`Overview request failed with ${response.status}`);
    }
    return response.json();
  }

  let retryTimer = null;

  function scheduleRetry() {
    if (retryTimer) return;
    retryTimer = window.setTimeout(() => {
      retryTimer = null;
      init().catch(() => {});
    }, OVERVIEW_RETRY_DELAY_MS);
  }

  async function init() {
    const overview = await loadOverview();
    if (!overview) {
      scheduleRetry();
      return;
    }
    renderOverviewGrid(overview);
  }

  init().catch((err) => {
    console.warn("Overview bootstrap failed:", err);
    scheduleRetry();
  });
})();

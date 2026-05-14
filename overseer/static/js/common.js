"use strict";

(() => {
  // Maximum rows to keep in each live feed table.
  const MAX_FEED_ROWS = 300;
  // Lowest allowed auto-scaled Y-axis ceiling for EPS charts.
  const SPARKLINE_MIN_Y = 10;
  // Prefix for persisting resizable table column widths in localStorage.
  const COLUMN_WIDTHS_KEY_PREFIX = "bergamot:column-widths:";
  // Smallest allowed width for a resizable table column.
  const MIN_COLUMN_WIDTH_PX = 64;

  function esc(str) {
    return String(str ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\"/g, "&quot;");
  }

  function fmtEventTs(ts_s, ts_ms, ms_ct) {
    const date = new Date(ts_s * 1000 + ts_ms);
    return date.toLocaleTimeString("en-US", {
      hour12: false,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      fractionalSecondDigits: ms_ct,
    }) + " " + date.toLocaleDateString("en-US");
  }

  function fmtCpuPct(value) {
    const n = Number(value ?? 0);
    if (!Number.isFinite(n)) return "0.00%";
    return `${n.toFixed(2)}%`;
  }

  function fmtRssKb(value) {
    const n = Number(value ?? 0);
    if (!Number.isFinite(n) || n <= 0) return "0 KiB";
    return `${n.toLocaleString("en-US")} KiB`;
  }

  function packetType(ev) {
    if (ev?.kind === "proc_snapshot") return "proc_snapshot";
    if (ev?.kind === "rich_proc_snapshot") return "rich_proc_snapshot";
    if (ev?.kind === "system_perf") return "system_perf";
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
    if (ev?.kind === "rich_proc_snapshot" && Array.isArray(ev?.processes)) {
      return `processes=${ev.processes.length}`;
    }
    if (ev?.kind === "system_perf" && Array.isArray(ev?.cores)) {
      return `cores=${ev.cores.length}`;
    }
    return "";
  }

  function packetArg2(ev) {
    if (ev?.arg2 != null) return ev.arg2;
    return "";
  }

  function packetRetval(ev) {
    if (ev?.retval != null) return ev.retval;
    return "";
  }

  function niceCeil(value) {
    if (!Number.isFinite(value) || value <= 0) return SPARKLINE_MIN_Y;
    const exponent = Math.floor(Math.log10(value));
    const unit = Math.pow(10, exponent);
    return Math.ceil(value / unit) * unit;
  }

  function connectEventStream({ onEvent, onStats, onPing } = {}) {
    const es = new EventSource("/api/stream");

    if (typeof onEvent === "function") {
      es.addEventListener("event", (e) => {
        try {
          onEvent(JSON.parse(e.data));
        } catch (_) {
          // Ignore malformed event packets.
        }
      });
    }

    if (typeof onStats === "function") {
      es.addEventListener("stats", (e) => {
        try {
          onStats(JSON.parse(e.data));
        } catch (_) {
          // Ignore malformed stats packets.
        }
      });
    }

    if (typeof onPing === "function") {
      es.addEventListener("ping", onPing);
    }

    es.onerror = () => {
      console.warn("SSE disconnected; browser will auto-reconnect.");
    };

    return es;
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
      if (idx === headers.length - 1) return;
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
              Math.min(
                Math.round(startWidth + delta),
                Math.round(startWidth + rightStartWidth - MIN_COLUMN_WIDTH_PX)
              )
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
            const widths = headers.slice(0, -1).map((h) => Math.round(h.getBoundingClientRect().width));
            saveColumnWidths(storageKey, widths);
          };

          document.addEventListener("mousemove", onMouseMove);
          document.addEventListener("mouseup", onMouseUp);
        });
      });
    });
  }

  window.BergamotCommon = {
    MAX_FEED_ROWS,
    esc,
    fmtEventTs,
    fmtCpuPct,
    fmtRssKb,
    packetType,
    packetArg1,
    packetArg2,
    packetRetval,
    niceCeil,
    connectEventStream,
    initResizableTables,
  };
})();

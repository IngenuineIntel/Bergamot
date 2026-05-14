"use strict";

(() => {
  const common = window.BergamotCommon;
  // Distance between cursor and hover details panel.
  const PROCESS_PANEL_CURSOR_OFFSET_PX = 18;
  // Keep hover details panel away from viewport edges.
  const PROCESS_PANEL_VIEWPORT_PADDING_PX = 12;

  function createProcessMap() {
    return {};
  }

  function replaceProcessMap(procMap, rows) {
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
        cpu_pct: Number(row.cpu_pct ?? 0),
        vm_rss_kb: Number(row.vm_rss_kb ?? 0),
        last_seen_s: Number(row.last_seen_s ?? 0),
        last_seen_ms: Number(row.last_seen_ms ?? 0),
      };
    });
  }

  function applyProcessSnapshot(procMap, snapshot) {
    const rows = Array.isArray(snapshot?.processes) ? snapshot.processes : [];
    replaceProcessMap(procMap, rows.map((row) => ({
      ...row,
      last_seen_s: Number(snapshot.ts_s ?? 0),
      last_seen_ms: Number(snapshot.ts_ms ?? 0),
    })));
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

  function processDetailsMarkup(procMap, row) {
    const liveProc = procMap[row.pid] || {};
    const details = [
      ["Start", common.fmtEventTs(row.start_ts_s, row.start_ts_ms, 3)],
      ["Last", common.fmtEventTs(row.last_ts_s, row.last_ts_ms, 3)],
      ["PID", row.pid ?? ""],
      ["PPID", row.ppid ?? ""],
      ["UID", row.uid ?? ""],
      ["Comm", row.comm ?? ""],
      ["Exec", row.exec_arg ?? ""],
      ["CPU", common.fmtCpuPct(row.cpu_pct ?? liveProc.cpu_pct)],
      ["RSS", common.fmtRssKb(row.vm_rss_kb ?? liveProc.vm_rss_kb)],
      ["Running", boolToYesNo(row.running)],
      ["Opens", row.open_count ?? 0],
      ["Connections", row.connect_count ?? 0],
      ["First Open", row.first_open ?? ""],
      ["First Connect", row.first_connect ?? ""],
    ];

    const lines = details
      .map(([label, value]) => `
    <div class="process-hover-details__label">${common.esc(label)}</div>
    <div class="process-hover-details__value">${common.esc(value)}</div>
  `)
      .join("");

    return `
    <div class="process-hover-details__title">Process Details</div>
    <div class="process-hover-details__grid">${lines}</div>
  `;
  }

  function findHostFrameElement() {
    if (window.parent === window) return null;

    let parentDoc;
    try {
      parentDoc = window.parent.document;
    } catch (_) {
      return null;
    }

    const frames = parentDoc.querySelectorAll("iframe[data-graph-frame]");
    for (const frame of frames) {
      try {
        const framePath = new URL(frame.getAttribute("src"), window.parent.location.href).pathname;
        if (framePath === window.location.pathname) return frame;
      } catch (_) {
        // Ignore malformed frame src values.
      }
    }

    return null;
  }

  function createProcessHoverController(procMap) {
    const state = {
      panelEl: null,
      hostWin: window,
      hostDoc: document,
      frameEl: null,
      hostResizeBound: false,
      activeRowKey: null,
      activeTableKind: null,
      mouseX: 0,
      mouseY: 0,
      localMouseX: 0,
      localMouseY: 0,
      rafId: null,
    };

    function resolveHost() {
      const frameEl = findHostFrameElement();
      if (!frameEl) {
        state.hostWin = window;
        state.hostDoc = document;
        state.frameEl = null;
        return;
      }

      state.hostWin = window.parent;
      state.hostDoc = window.parent.document;
      state.frameEl = frameEl;

      if (!state.hostResizeBound) {
        state.hostResizeBound = true;
        state.hostWin.addEventListener("resize", schedulePositionUpdate);
      }
    }

    function updateMouse(clientX, clientY) {
      state.localMouseX = clientX;
      state.localMouseY = clientY;

      if (state.frameEl) {
        const rect = state.frameEl.getBoundingClientRect();
        state.mouseX = rect.left + clientX;
        state.mouseY = rect.top + clientY;
        return;
      }

      state.mouseX = clientX;
      state.mouseY = clientY;
    }

    function ensurePanel() {
      if (state.panelEl) return state.panelEl;

      resolveHost();
      const panel = state.hostDoc.createElement("aside");
      panel.className = "process-hover-details";
      panel.setAttribute("aria-hidden", "true");
      state.hostDoc.body.appendChild(panel);

      state.panelEl = panel;
      return panel;
    }

    function updatePosition() {
      const panel = state.panelEl;
      if (!panel || !panel.classList.contains("is-visible")) return;

      const panelWidth = panel.offsetWidth;
      const panelHeight = panel.offsetHeight;
      const viewportWidth = state.hostWin.innerWidth;
      const viewportHeight = state.hostWin.innerHeight;
      const maxX = Math.max(
        PROCESS_PANEL_VIEWPORT_PADDING_PX,
        viewportWidth - panelWidth - PROCESS_PANEL_VIEWPORT_PADDING_PX
      );
      const maxY = Math.max(
        PROCESS_PANEL_VIEWPORT_PADDING_PX,
        viewportHeight - panelHeight - PROCESS_PANEL_VIEWPORT_PADDING_PX
      );

      const clampX = (x) => Math.max(PROCESS_PANEL_VIEWPORT_PADDING_PX, Math.min(x, maxX));
      const clampY = (y) => Math.max(PROCESS_PANEL_VIEWPORT_PADDING_PX, Math.min(y, maxY));
      const mx = state.mouseX;
      const my = state.mouseY;

      const candidates = [
        { x: mx + PROCESS_PANEL_CURSOR_OFFSET_PX, y: my + PROCESS_PANEL_CURSOR_OFFSET_PX },
        { x: mx - panelWidth - PROCESS_PANEL_CURSOR_OFFSET_PX, y: my + PROCESS_PANEL_CURSOR_OFFSET_PX },
        { x: mx + PROCESS_PANEL_CURSOR_OFFSET_PX, y: my - panelHeight - PROCESS_PANEL_CURSOR_OFFSET_PX },
        { x: mx - panelWidth - PROCESS_PANEL_CURSOR_OFFSET_PX, y: my - panelHeight - PROCESS_PANEL_CURSOR_OFFSET_PX },
      ];

      let x = clampX(candidates[0].x);
      let y = clampY(candidates[0].y);

      for (const candidate of candidates) {
        const cx = clampX(candidate.x);
        const cy = clampY(candidate.y);
        const overlapsCursor = mx >= cx && mx <= cx + panelWidth && my >= cy && my <= cy + panelHeight;
        if (!overlapsCursor) {
          x = cx;
          y = cy;
          break;
        }
      }

      panel.style.left = `${Math.round(x)}px`;
      panel.style.top = `${Math.round(y)}px`;
    }

    function schedulePositionUpdate() {
      if (state.rafId != null) return;

      state.rafId = window.requestAnimationFrame(() => {
        state.rafId = null;
        updatePosition();
      });
    }

    function hide() {
      const panel = state.panelEl;
      if (!panel) return;

      panel.classList.remove("is-visible");
      panel.setAttribute("aria-hidden", "true");
      state.activeRowKey = null;
      state.activeTableKind = null;
    }

    function show(row, tableKind) {
      const panel = ensurePanel();
      panel.innerHTML = processDetailsMarkup(procMap, row);
      panel.classList.add("is-visible");
      panel.setAttribute("aria-hidden", "false");

      state.activeRowKey = processRowKey(row);
      state.activeTableKind = tableKind;
      schedulePositionUpdate();
    }

    function bindRow(tr, row, tableKind) {
      tr.classList.add("process-hover-row");
      tr.dataset.processHover = "1";
      tr.dataset.processHoverKey = processRowKey(row);
      tr.__processHoverRow = row;
      tr.__processHoverTableKind = tableKind;

      tr.addEventListener("mouseenter", (event) => {
        updateMouse(event.clientX, event.clientY);
        show(row, tableKind);
      });

      tr.addEventListener("mousemove", (event) => {
        updateMouse(event.clientX, event.clientY);
        if (!state.activeRowKey) {
          show(row, tableKind);
          return;
        }
        schedulePositionUpdate();
      });

      tr.addEventListener("mouseleave", () => {
        hide();
      });
    }

    function syncAfterRowsRender() {
      if (!state.activeRowKey) return;

      const el = document.elementFromPoint(state.localMouseX, state.localMouseY);
      const rowEl = el?.closest?.("tr[data-process-hover='1']");
      if (!rowEl || !rowEl.__processHoverRow || !rowEl.__processHoverTableKind) {
        hide();
        return;
      }

      const nextKey = rowEl.dataset.processHoverKey || "";
      if (nextKey !== state.activeRowKey || rowEl.__processHoverTableKind !== state.activeTableKind) {
        show(rowEl.__processHoverRow, rowEl.__processHoverTableKind);
      } else {
        schedulePositionUpdate();
      }
    }

    window.addEventListener("resize", schedulePositionUpdate);

    return {
      bindRow,
      syncAfterRowsRender,
      schedulePositionUpdate,
    };
  }

  window.BergamotProcesses = {
    createProcessMap,
    replaceProcessMap,
    applyProcessSnapshot,
    createProcessHoverController,
  };
})();

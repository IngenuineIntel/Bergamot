"use strict";

(function () {
  const DEFAULT_MIN_HEIGHT = 180;
  const MIN_HEIGHT_BY_PATH = new Map([
    ["/graph/overview", 0],
  ]);
  const frameSelector = "iframe[data-graph-frame]";
  const LOCKED_HEIGHT_PATHS = new Set([
    "/graph/lifecycle",
    "/graph/dead-processes",
  ]);
  const reportedHeights = new Map();
  let manualLockedHeight = null;

  function minHeightForPath(path) {
    return MIN_HEIGHT_BY_PATH.get(path) ?? DEFAULT_MIN_HEIGHT;
  }

  function getLockedFrames() {
    const lifecycleFrame = getFrameByPath("/graph/lifecycle");
    const deadProcessesFrame = getFrameByPath("/graph/dead-processes");
    if (!lifecycleFrame || !deadProcessesFrame) return null;
    return [lifecycleFrame, deadProcessesFrame];
  }

  function applyLockedHeight(height) {
    const frames = getLockedFrames();
    if (!frames) return;

    const syncedHeight = Math.max(DEFAULT_MIN_HEIGHT, Math.round(Number(height) || 0));
    frames.forEach((frame) => {
      frame.style.height = `${syncedHeight}px`;
    });
  }

  function autoLockedHeight() {
    return Math.max(
      DEFAULT_MIN_HEIGHT,
      reportedHeights.get("/graph/lifecycle") || DEFAULT_MIN_HEIGHT,
      reportedHeights.get("/graph/dead-processes") || DEFAULT_MIN_HEIGHT,
    );
  }

  function initLockedFrameResizer() {
    const details = document.querySelector(".iframe-dropdown-group");
    if (!details) return;

    const grid = details.querySelector(".iframe-dropdown-grid");
    if (!grid) return;

    const lockedFrames = getLockedFrames();
    if (!lockedFrames) return;

    const handle = document.createElement("div");
    handle.className = "graph-frame-bottom-resizer";
    handle.setAttribute("role", "separator");
    handle.setAttribute("aria-orientation", "horizontal");
    handle.setAttribute("aria-label", "Resize process lifecycle frames");
    details.appendChild(handle);

    handle.addEventListener("mousedown", (downEvent) => {
      downEvent.preventDefault();

      const [frame] = getLockedFrames() || [];
      if (!frame) return;

      const startY = downEvent.clientY;
      const startHeight = Math.round(frame.getBoundingClientRect().height);
      document.body.classList.add("is-resizing-frames");

      const onMouseMove = (moveEvent) => {
        const deltaY = moveEvent.clientY - startY;
        manualLockedHeight = Math.max(DEFAULT_MIN_HEIGHT, startHeight + deltaY);
        applyLockedHeight(manualLockedHeight);
      };

      const onMouseUp = () => {
        document.removeEventListener("mousemove", onMouseMove);
        document.removeEventListener("mouseup", onMouseUp);
        document.body.classList.remove("is-resizing-frames");
      };

      document.addEventListener("mousemove", onMouseMove);
      document.addEventListener("mouseup", onMouseUp);
    });
  }

  function getFrameByPath(path) {
    const frames = document.querySelectorAll(frameSelector);
    for (const frame of frames) {
      try {
        const framePath = new URL(frame.getAttribute("src"), window.location.href).pathname;
        if (framePath === path) return frame;
      } catch (_) {
        // Ignore malformed src values.
      }
    }
    return null;
  }

  window.addEventListener("message", (event) => {
    if (event.origin !== window.location.origin) return;
    const data = event.data || {};
    if (data.type !== "graph-height" || typeof data.path !== "string") return;

    const nextHeight = Math.max(minHeightForPath(data.path), Number(data.height) || 0);
    if (nextHeight <= 0) return;

    if (LOCKED_HEIGHT_PATHS.has(data.path)) {
      reportedHeights.set(data.path, nextHeight);

      if (manualLockedHeight != null) {
        applyLockedHeight(manualLockedHeight);
        return;
      }

      applyLockedHeight(autoLockedHeight());
      return;
    }

    const frame = getFrameByPath(data.path);
    if (!frame) return;
    frame.style.height = `${nextHeight}px`;
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initLockedFrameResizer, { once: true });
  } else {
    initLockedFrameResizer();
  }
})();

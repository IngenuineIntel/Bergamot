"use strict";

(function () {
  const MIN_HEIGHT = 180;
  const frameSelector = "iframe[data-graph-frame]";
  const LOCKED_HEIGHT_PATHS = new Set([
    "/graph/lifecycle",
    "/graph/dead-processes",
  ]);
  const reportedHeights = new Map();

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

    const nextHeight = Math.max(MIN_HEIGHT, Number(data.height) || 0);
    if (nextHeight <= 0) return;

    if (LOCKED_HEIGHT_PATHS.has(data.path)) {
      reportedHeights.set(data.path, nextHeight);

      const lifecycleFrame = getFrameByPath("/graph/lifecycle");
      const deadProcessesFrame = getFrameByPath("/graph/dead-processes");
      if (!lifecycleFrame || !deadProcessesFrame) return;

      const syncedHeight = Math.max(
        MIN_HEIGHT,
        reportedHeights.get("/graph/lifecycle") || MIN_HEIGHT,
        reportedHeights.get("/graph/dead-processes") || MIN_HEIGHT,
      );

      lifecycleFrame.style.height = `${syncedHeight}px`;
      deadProcessesFrame.style.height = `${syncedHeight}px`;
      return;
    }

    const frame = getFrameByPath(data.path);
    if (!frame) return;
    frame.style.height = `${nextHeight}px`;
  });
})();

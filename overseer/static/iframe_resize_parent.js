"use strict";

(function () {
  const MIN_HEIGHT = 180;
  const frameSelector = "iframe[data-graph-frame]";

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

    const frame = getFrameByPath(data.path);
    if (!frame) return;

    const nextHeight = Math.max(MIN_HEIGHT, Number(data.height) || 0);
    if (nextHeight > 0) {
      frame.style.height = `${nextHeight}px`;
    }
  });
})();

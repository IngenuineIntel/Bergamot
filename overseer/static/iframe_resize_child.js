"use strict";

(function () {
  let queued = false;

  function postHeight() {
    const body = document.body;
    const root = document.documentElement;
    const height = Math.max(
      body ? body.scrollHeight : 0,
      root ? root.scrollHeight : 0,
      body ? body.offsetHeight : 0,
      root ? root.offsetHeight : 0
    );

    window.parent.postMessage(
      {
        type: "graph-height",
        path: window.location.pathname,
        height,
      },
      window.location.origin
    );
  }

  function scheduleHeightPost() {
    if (queued) return;
    queued = true;
    window.requestAnimationFrame(() => {
      queued = false;
      postHeight();
    });
  }

  window.addEventListener("load", scheduleHeightPost);
  window.addEventListener("resize", scheduleHeightPost);

  const observer = new MutationObserver(scheduleHeightPost);
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    characterData: true,
  });

  setInterval(scheduleHeightPost, 1000);
})();

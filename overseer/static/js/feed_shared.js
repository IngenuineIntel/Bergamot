"use strict";

(() => {
  // Feed row cap is configured centrally in common.js.
  const common = window.BergamotCommon;

  function prependLimitedRow(tbody, markup) {
    if (!tbody) return;

    const tr = document.createElement("tr");
    tr.innerHTML = markup;
    tbody.insertBefore(tr, tbody.firstChild);

    while (tbody.rows.length > common.MAX_FEED_ROWS) {
      tbody.deleteRow(tbody.rows.length - 1);
    }
  }

  function renderRecentRows(rows, renderer) {
    [...rows].reverse().forEach((row) => renderer(row));
  }

  window.BergamotFeeds = {
    prependLimitedRow,
    renderRecentRows,
  };
})();

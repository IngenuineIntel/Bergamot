// uptime.js
// managing uptime feeds on the front page

"use strict";

// time between fetching the API to see if an agent's connected to the backend
// measured in seconds
const UPTIME_CHECK_WAIT = 5;
const MENU_UPTIME_ID    = "uptime";

async function renderUptime() {
  /* Renders  */
  const req = await fetch("/api/uptime");
  const j = await req.json();
  const uptime = Number(j.uptime ?? 0);
  if (uptime > 0) {
    return `LIVE for ${fmtTimeAmount(uptime)}`;
  } else {
    return "No Connections";
  }
}

const manageUptime = setTimeout(() => {
    document.getElementById(MENU_UPTIME_ID).innerText = renderUptime();
}, UPTIME_CHECK_WAIT * 1000);

/* TODO make this not show [object Promise] */
/* TODO make number go up on its own without fetching /api/uptime */

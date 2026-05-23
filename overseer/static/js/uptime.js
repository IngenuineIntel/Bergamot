// uptime.js
// managing uptime feeds on the front page

"use strict";

const portTag = document.getElementById("uptime");

let uptimeKeepup = 0;
let epochFetchMod = 5;
let epochFetchStat = 0;

function ProcessAndRenderUptime(uptime) {
  if (!uptime) {
    portTag.innerText = "No Connections";
  } else {
    portTag.innerText = `LIVE for ${fmtTimeAmount(uptime)}`
  }
}

async function uptimeEpoch() {
    if(uptimeKeepup >= epochFetchMod) {
    fetch("/api/uptime").then(
      res => res.json()
    ).then(data => {
      ProcessAndRenderUptime(data.uptime);
    }).catch(
      err => console.error("Error:", error)
    );
  } else {
    uptimeKeepup++;
    epochFetchStat++;
    ProcessAndRenderUptime();
  }
}

const manageUptime = setTimeout(() => {
  uptimeEpoch();
}, 1000);

/* TODO make this work, it's broke atm */
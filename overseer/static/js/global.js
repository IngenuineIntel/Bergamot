// global.js
// holds general-use things that everyone needs in their lives

"use strict";

function fmtTimeAmount(seconds, clock_style = false) {
  /* Formats a number of seconds into a formatted string 
   *
   * clock_style = true:
   * 23:59:59
   * 
   * clock_style = false:
   * 23h 59m 59s
   */
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (clock_style == true) {
    return `${h}:${m}:${s}`;
  } // else
    return `${h}h ${m}m ${s}s`;
}

function fmtEventTs(ts_s, ts_ms, ms_ct) {
  /* Formats a UNIX timestampt (ts_s) plus milliseconds (ts_ms) to a formatted
   * date/time string with (ms_ct) decimal points */
  const date = new Date(ts_s * 1000 + ts_ms);
  return date.toLocaleTimeString('en-US', {
    hour12: false,
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    fractionalSecondDigits: ms_ct
  }) + " " + date.toLocaleDateString('en-US');
}

/* LIGHT/DARK mode */
// usually this stuff is done in a more automatic way, but I want to be able
// to change the mode from the console for debugging

const html = document.querySelector("html");

function darkMode() {
  html.classList.remove("light-mode");
}

function lightMode() {
  html.classList.add("light-mode");
}

const wantsDarkMode = window.matchMedia(
  '(prefers-color-scheme: dark)'
).matches;

if (!wantsDarkMode) {
  // wantsLightMode
  lightMode();
}

/* Store this stuff so it survives DOM reload */

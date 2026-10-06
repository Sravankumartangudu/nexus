// nexus-beacon.js — drop-in heartbeat for Nexus (the fleet monitor), for Electron / Node apps.
//
// To make an Electron app visible to Nexus with live health, in the main process (main.js):
//   const nexus = require("./nexus-beacon");
//   nexus.start({ id: "local.water-buddy", name: "Water Buddy", version: app.getVersion() });
//   // optionally report richer health each beat:
//   nexus.start({ id: "local.water-buddy", name: "Water Buddy", version: app.getVersion(),
//                 status: () => paused ? ["warn", "reminders paused"] : ["ok", "on duty"] });
//
// Writes ~/.nexus/heartbeats/<id>.json every 30s and a final "offline" beat on quit.
// No dependency on Nexus being installed; safe to require unconditionally.

const fs = require("fs");
const os = require("os");
const path = require("path");

let opts = null;
let timer = null;

function dir() {
  return path.join(os.homedir(), ".nexus", "heartbeats");
}

function write(status, detail) {
  if (!opts) return;
  try {
    fs.mkdirSync(dir(), { recursive: true });
    const obj = {
      id: opts.id, name: opts.name, version: opts.version || "?",
      pid: process.pid, status, detail: detail || "",
      ts: Math.floor(Date.now() / 1000),
    };
    fs.writeFileSync(path.join(dir(), `${opts.id}.json`), JSON.stringify(obj, null, 2));
  } catch (_) { /* heartbeat is best-effort */ }
}

function beat() {
  let status = "ok", detail = "";
  if (typeof opts.status === "function") {
    try { const r = opts.status(); if (Array.isArray(r)) { status = r[0]; detail = r[1] || ""; } } catch (_) {}
  }
  write(status, detail);
}

function start(options) {
  opts = options;
  beat();
  timer = setInterval(beat, 30000);
  if (timer.unref) timer.unref();
  const bye = () => write("offline", "quit");
  process.on("exit", bye);
  process.on("SIGTERM", () => { bye(); process.exit(0); });
  process.on("SIGINT", () => { bye(); process.exit(0); });
}

module.exports = { start, beat };

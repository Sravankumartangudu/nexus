# Changelog

## 1.3 — 2026-10-07

- **Orb Size**: a new menu (Tiny / Small / Medium / Large / Extra Large) to make the floating orb bigger
  or smaller. It resizes in place, stays on screen, and redraws sharply at every size.

## 1.2 — 2026-10-06

- **Natural-language voice** — Nexus now understands plain English, not just fixed keywords. Quick
  commands ("open Jarvis", "stop all") still run instantly and offline; anything else is handed to
  a local Claude brain that answers questions about how the fleet is doing and can act on it
  (including bringing every agent up at once). Requires the `claude` CLI; on by default when present.

## 1.1 — 2026-10-06

- **Operations Center** dashboard — a flagship spatial command-centre view (now the default):
  agent "pods" orbit a central NEXUS core with animated command/telemetry beams.
- **Voice control** — wake word "Nexus" (add your own names), on-device speech recognition, and
  spoken commands to open / start / stop / restart / rebuild any agent or the whole fleet, plus a
  spoken status report. Off by default.
- **Voice orb** — a floating, draggable animated orb reflecting the voice state, with selectable
  styles including a **Fleet** style that mirrors the dashboard's active/idle agent counts.
- **Launch at login** via `SMAppService` — only Nexus needs a login item; it wakes the rest.
- **DMG installer** (`package.sh`) for drag-to-Applications install.
- Full documentation: prerequisites, install, and usage.

## 1.0 — 2026-10-06

First release. Nexus — the head of the fleet.

- Menu-bar app that monitors every other app in the home folder, with the menu-bar icon tinted to
  the worst status across the fleet.
- Full dashboard window (WebKit) with a card per app: status, version, detail, and controls.
- Automatic discovery of Swift and Electron apps in `~`, plus `~/.nexus/apps.json` for apps
  elsewhere — new apps appear with no configuration.
- Two monitoring layers: process-level (running state, version, build freshness, crash detection)
  for any app, and an opt-in file-based heartbeat for richer `ok`/`warn`/`error` health.
- Drop-in beacons for Swift (`NexusBeacon.swift`) and Electron (`nexus-beacon.js`).
- Per-app actions: Open/Restart, Stop, Rebuild (background, logged to `~/.nexus/logs/`), Reveal.
- `--probe` headless text view for scripting.
- Beacons wired into Animi, Sev1 Siren, Jarvis, OrgCS Pulse, and Water Buddy.

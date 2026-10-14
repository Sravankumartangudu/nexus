# Changelog

## 1.7.0 — 2026-10-15

- **🎨 Appearance: System / Light / Dark.** Pick it in the menu (🎨 Appearance) or in Settings.
  It applies at once; System follows macOS (Auto included).
- The dashboard has a new light theme (all seven views), and keeps its dark look unchanged.
- The voice orb looks the same in every mode.

## 1.6.1 — 2026-10-13

- Finds apps kept in a `mac/` subfolder, as well as `app/`. WheatWise keeps its Mac app in `mac/`,
  beside its agent and web dashboard, so Nexus missed it. Its icon was hidden in the folder but not listed.

## 1.6 — 2026-10-13

- **A menu-bar folder for the fleet.** Each app's submenu now starts with that app's own menu,
  mirrored live, so you can use any app from Nexus. Picking an item runs it in the app.
  - **Keep Agents in Nexus** (menu) hides the apps' own menu-bar icons. **Show Icon in Menu Bar**
    in an app's submenu keeps that one visible.
  - Whenever Nexus isn't running, every app shows its icon again.
- **Beacon v2.** `NexusBeacon.attach(item)` (Swift) and `nexus.attach({ menu, setVisible })`
  (Electron) let an app live in the folder. It shares its menu through `~/.nexus/menus/`, takes
  commands from `~/.nexus/inbox/` and follows `~/.nexus/folder.json`. Apps on the older beacon are
  listed as before. See the README.

## 1.5 — 2026-10-13

- **Teams.** The fleet is grouped by where each app's repo is published: **Work** (the work GitHub,
  git.soma), **Personal** (github.com) and **Local** (not on git yet). Nexus reads each app's git
  `origin`, so an app moves to the right team as soon as it's pushed. You can override the team
  with `"team"` in `~/.nexus/apps.json`.
  - Menu: a heading per team with its running count. Each app's submenu shows its team and repo.
  - Dashboard: a team picker that filters every view. The Status Grid has a section per team, and
    the popup for an app shows its team and repo.
  - Voice: team commands such as "open work", "stop all personal" and "work status". The Claude
    brain sees each agent's team too.
  - `--probe` lists apps under their team.
- Operations Center and Constellation space their agents evenly around the core. Before, agents could
  drift on top of each other.

## 1.4 — 2026-10-12

- **Finds apps kept in an `app/` subfolder.** Discovery used to look only at the top of each folder in `~`, so an app whose `build.sh` and `.app` sit in `<folder>/app/` (such as Log Doctor, next to its engine) never showed up, even with its beacon running. Nexus now checks there too. Rebuild and Open work on that folder as usual.
- Sev1 Siren is no longer listed: it was merged into OrgCS Pulse.

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

# Nexus

**The head of the personal fleet.** A macOS menu-bar app that watches every personal app you've
built — and every one you build in the future — showing a live green/amber/red health status for each, plus a
full dashboard window, voice control, and a floating voice orb.

Nexus is the parent of the personal family: Animi, Water Buddy, WheatWise, T-Minus, and whatever
comes next. It owns no app's logic; it just keeps an eye on all of them — and, on a spoken command,
wakes, opens, stops, or rebuilds any of them for you.

Work apps (those on the work GitHub) have their own parent, **Citadel**, built from this same core
and kept on the work GitHub. See [One core, two parents](#one-core-two-parents).

---

## Prerequisites

- **macOS 13 (Ventura) or newer** — Nexus is a universal (Apple Silicon + Intel) menu-bar app.
- **Xcode Command Line Tools** — provides `swiftc`, `lipo`, and `codesign`:
  ```bash
  xcode-select --install
  ```
- **A microphone** — only if you want voice control (optional; off by default).
- **The `claude` CLI** — optional, only for natural-language voice. If [Claude Code](https://docs.claude.com/en/docs/claude-code)
  is installed and on your `PATH`, Nexus uses it to understand plain-English questions and requests;
  without it, voice still works with the built-in keyword commands.
- No other required dependencies, no runtime. Nexus itself makes no network calls (the optional
  `claude` brain does, when you speak to it).

> Nexus runs as a background agent (`LSUIElement`) — it lives in the menu bar with **no Dock icon
> and no main window**.

---

## Install

### Option A — DMG installer (easiest)

Download the latest `Nexus-<version>.dmg` from the [Releases](../../releases) page, open it, and
drag **Nexus** onto the **Applications** folder — just like any Mac app. See `Read Me First.txt`
inside the DMG for the one-time "Open Anyway" step (Nexus isn't notarized by Apple).

To build the DMG yourself:

```bash
./package.sh               # builds a universal app and writes dist/Nexus-<version>.dmg
```

### Option B — build from source

```bash
git clone https://github.com/Sravankumartangudu/nexus.git
cd nexus
./build.sh                 # builds Nexus.app for your Mac's architecture
# or, for a universal binary (Apple Silicon + Intel):
./build.sh --universal
open Nexus.app             # launches it into the menu bar
```

To keep it running, drag `Nexus.app` into `/Applications` and enable **Launch Nexus at Login**
from its menu (see below).

The build ad-hoc code-signs the app so that microphone / speech permissions, once granted, stick
across launches.

---

## Usage

Click the menu-bar icon (its colour reflects the **worst** status across the whole fleet) to open
the menu. From there you get the fleet list, per-app controls, and every toggle below.

### What each status means

| Status | Colour | Meaning |
|---|---|---|
| Running | 🟢 | Alive and (if it has a beacon) reporting healthy |
| Needs rebuild | 🟡 | Source files are newer than the built app |
| Warning | 🟡 | The app's own beacon reports a `warn` state |
| Not responding | 🟡 | Running but its heartbeat has gone stale (hung) |
| Error | 🔴 | The app's beacon reports an `error` state |
| Crashed | 🔴 | Was beating, then vanished without a clean quit |
| Idle | ⚪ | Built, not running, nothing wrong |
| Not built | ⚪ | No `.app` yet — run its `build.sh` |

### The dashboard

**Open Dashboard…** opens a draggable window with a live, animated view of the whole fleet. Pick
a visualisation from the menu-bar **Dashboard Style** submenu or the in-window picker:

- **Operations Center** *(default, flagship)* — a spatial command centre: each agent is a "pod"
  orbiting a central **NEXUS** core, with animated beams carrying command/telemetry packets whose
  traffic scales with each agent's status.
- **Office** — a walking-agent simulation.
- **Constellation**, **City**, **NOC**, **Terminal**, **Grid** — alternative layouts.

Spatial views share one orbit camera: **drag** to orbit, **wheel** to zoom, **⇧-drag / right-drag**
to pan, and **Reset view** to recenter.

**🎨 Appearance** (menu or Settings) switches the app between **System**, **Light** and **Dark**
at once; System follows macOS. The voice orb looks the same in every mode.

### Teams

Nexus groups the fleet into **teams** by where each app's code is published. It reads the `origin`
remote from the app's git repo. Nexus watches every team except **Work**, which belongs to Citadel:

| Team | Repo lives on |
|---|---|
| **Work** | the work GitHub (`git.soma.salesforce.com`) — watched by Citadel, not Nexus |
| **Personal** | public `github.com` |
| **Local** | not on git yet (a new app starts here; add its `origin` remote to move it) |
| *host name* | any other git host, e.g. `gitlab.com` |

The menu lists apps under a heading for each team, with its running count. Each app's submenu shows
its team and repo. In the dashboard, the **team picker** (left of the style picker) shows one team
or all of them. The Status Grid splits into a section per team. Nothing needs configuring: point an
app at a new remote and it moves to the matching team (and parent) on the next refresh. A new work
app moves to Citadel as soon as its `origin` is set to the work GitHub — before the first push. To put an app in a
different team, set `"team"` for it in `~/.nexus/apps.json` (see below).

### Menu-bar folder

Nexus can hold the fleet in one menu-bar icon. Each app's submenu starts with **that app's own menu**,
mirrored live, so picking an item there does exactly what it does from the app's own icon. macOS
won't let one app hold another's menu-bar item, so each app's beacon shares its menu with Nexus and
runs the items you pick (beacon v2, see below).

- **Keep Agents in Nexus** (menu) hides the apps' own menu-bar icons.
- **Show Icon in Menu Bar** in an app's submenu keeps that one app's icon visible while the folder is on.
- Whenever Nexus isn't running, every app shows its icon again, so no app is ever out of reach.

Apps on the older beacon are listed as before, without their menu, and keep their own icons.

### Per-app controls

From the menu bar or the dashboard, for each app: **Open / Restart**, **Stop**, **Rebuild** (runs
its `build.sh` or `npm run dist` in the background, logging to `~/.nexus/logs/`), and **Reveal in
Finder**. There's also **Rebuild All** and **Refresh Now**.

### Voice control (optional)

Nexus can listen for a wake word and run spoken commands — it's the fleet's wake-up switch.
Enable **Voice Control** from the menu (or Settings). On first use macOS will ask for
**Microphone** and **Speech Recognition** permission.

- **Wake word:** say **"Nexus"**. You can add your own names in **Settings → Wake words**.
  (Citadel answers to **"Citadel"**, so both can listen at once.)
- **Commands** (after the wake word): open / start / activate / stop / restart / rebuild a named
  agent — e.g. *"Nexus, open Animi"*, *"Nexus, restart Water Buddy"* — or address the whole fleet
  (*"stop all"*, *"rebuild all"*) or a whole team (*"open personal"*, *"stop all local"*, *"personal
  status"*). Ask *"status"* for a spoken fleet report, or *"open dashboard"*.

Speech recognition is on-device where supported; set your **Recognition accent** in Settings for
better accuracy.

**Natural language.** The commands above are matched instantly and offline. Anything phrased more
naturally — or a *question* like *"how are the agents doing?"*, *"which ones are down?"*, *"bring
everything online"* — is handed to a local **Claude brain** (the `claude` CLI, if installed). It
sees a live snapshot of the fleet, answers in a sentence or two, and can act on the fleet when you
ask. On by default when the CLI is present; it falls back to keyword commands otherwise.

### Voice orb (optional)

**Show Orb** floats a Jarvis-style animated orb on screen that reflects the voice state (idle /
listening / working / speaking). **Click** it to start listening, **drag** to move it,
**right-click** for the fleet menu. Resize it under **Orb Size** (Tiny / Small / Medium / Large /
Extra Large). Choose its look under **Orb Style**, including a **Fleet**
style whose orbiting satellites mirror the dashboard's agent count (lit = active, dimmed = idle,
with a live `running / total` readout in the core).

### Launch at login

**Launch Nexus at Login** registers Nexus as a login item. Because Nexus can wake the other agents
on voice command, only Nexus needs its own login item — the others don't.

### Headless probe

```bash
./Nexus.app/Contents/MacOS/Nexus --probe     # prints a text view of the fleet, for scripting
```

---

## How it works

Two independent signals, combined per app:

1. **Process-level** (zero cooperation needed). Nexus scans the home folder for apps, checks which
   are running (via the running-applications list and live PIDs), reads each app's version from
   its bundle, and compares source timestamps against the built binary to flag stale builds. This
   works for *any* app, including ones with no Nexus integration at all.

2. **Heartbeat** (richer, opt-in per app). Each app drops a tiny JSON file in
   `~/.nexus/heartbeats/<bundleid>.json` every 30 seconds via a drop-in beacon. That lets Nexus see
   the running version, an app-defined `ok` / `warn` / `error` state with a human detail string,
   and detect a clean quit vs. a crash. No ports, no servers, no network — just a file.

### Auto-discovery

Nexus scans `~` for anything that looks like one of these apps (a Swift app with a `build.sh`, or
an Electron app), either at the top of a folder or in its `app/` or `mac/` subfolder, and shows it automatically. **Build a new app in your home folder and it appears
in Nexus with no configuration.** To track an app that lives elsewhere, add it to
`~/.nexus/apps.json`:

```json
[
  { "name": "My Service", "dir": "/Users/you/code/my-service", "kind": "electron", "id": "local.my-service",
    "team": "Work" }
]
```

`team` is optional. Without it, the team comes from the app's git remote.

---

## Adding the heartbeat to an app

**Swift app:** copy `beacon/NexusBeacon.swift` into the app folder, add `NexusBeacon.swift` to the
`swiftc` source list in its `build.sh`, and call it once at launch:

```swift
func applicationDidFinishLaunching(_ n: Notification) {
    NexusBeacon.start(name: "My App")
    // ...optionally report live health:
    // NexusBeacon.start(name: "My App") { busy ? ("warn", "catching up") : ("ok", "idle") }
}
```

**Electron app:** copy `beacon/nexus-beacon.js` into the app folder and start it in the main process:

```js
const nexus = require('./nexus-beacon');
nexus.start({ id: 'local.my-app', name: 'My App', version: app.getVersion(),
              status: () => paused ? ['warn', 'paused'] : ['ok', 'on duty'] });
```

The beacon is self-contained and has no dependency on Nexus being installed — it's safe to ship.

### Living in the menu-bar folder

To let an app's menu show in Nexus and its icon hide with **Keep Agents in Nexus**, hand the beacon
the menu-bar item once it has its menu:

```swift
item.menu = menu
NexusBeacon.attach(item)
```

For Electron, pass a function returning the tray menu's template and a way to show or hide the tray:

```js
nexus.attach({ menu: () => trayTemplate(), setVisible: (on) => on ? makeTray() : dropTray() });
```

Everything goes through files under `~/.nexus/`:

| File | Written by | What it holds |
|---|---|---|
| `menus/<bundleid>.json` | the app | its menu: entries `{i, t, e, s, k}` (index, title, enabled, checked, submenu) or `{i, sep: true}` |
| `inbox/<bundleid>/*.json` | Nexus | commands: `{"cmd":"dump"}` (write the menu), `{"cmd":"folder"}` (re-read folder.json), `{"cmd":"perform","path":[…],"title":"…"}` (run an item) |
| `folder.json` | Nexus | `{"enabled": bool, "shown": [bundleids]}` (Citadel keeps its own, `citadel-folder.json`) |

The app hides its item only while the folder is on, its parent is running, and the app isn't on the
`shown` list. Which parent an app lives under is set by two constants at the top of its copy of
`NexusBeacon.swift` (`nexusId` and `folderFile`): personal apps keep Nexus's, work apps get Citadel's.

---

## One core, two parents

Nexus and Citadel are the same app with a different `Edition.swift`. That file holds everything that
makes a parent itself: its name (also the default wake word), bundle id, folder file, menu-bar
symbol, which teams it watches, and two hooks where its own features plug in (`setUp()` at launch,
`addMenuItems(to:)` in the menu). Everything else — `main.swift`, `Fleet.swift`, `Voice.swift`,
`Brain.swift`, `Folder.swift`, `dashboard.html`, `orb.html` and the beacon — is the shared core.

This repo is the master copy of the core. Citadel lives on the work GitHub and copies the core in
with its own sync script; nothing goes the other way, so Citadel's work-only features stay there.
Fix or add shared features here, then sync them into Citadel.

---

## Layout

- `Edition.swift` — what makes this parent Nexus: name, teams watched, symbol, feature hooks
- `main.swift` — menu bar, dashboard window, voice/orb wiring, per-app actions, refresh loop
- `Fleet.swift` — discovery, heartbeat reading, status computation
- `Folder.swift` — the menu-bar folder: mirrored app menus, commands to apps, folder settings
- `Voice.swift` — wake-word listening, command parsing, speech synthesis
- `Brain.swift` — natural-language understanding and fleet actions via the local `claude` CLI
- `dashboard.html` — the dashboard UI and its visualisation styles
- `orb.html` — the floating voice orb
- `beacon/NexusBeacon.swift`, `beacon/nexus-beacon.js` — drop-in heartbeat libraries
- `Icon/make_icon.swift` — generates the app icon
- `build.sh` — compiles, bundles, and ad-hoc signs `Nexus.app`
- `package.sh` — builds the universal app and a drag-to-Applications DMG under `dist/`

---

## Privacy

Everything Nexus does is local. Heartbeats are files under `~/.nexus/`; discovery reads your home
folder; speech recognition is on-device where macOS supports it. Nexus makes no network calls.

---

## License

[MIT](LICENSE) © Sravan Kumar Tangudu

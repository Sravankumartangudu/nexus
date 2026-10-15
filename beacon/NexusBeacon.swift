// NexusBeacon — drop-in heartbeat for Nexus (the fleet monitor).
//
// To make any Swift app visible to Nexus with live health:
//   1. Copy this file into the app folder and add NexusBeacon.swift to build.sh's source list.
//   2. Call once at launch, e.g. in applicationDidFinishLaunching:
//          NexusBeacon.start(name: "Jarvis")
//      or, to report richer health, pass a closure returning (status, detail):
//          NexusBeacon.start(name: "Jarvis") { Voice.isListening ? ("ok", "listening") : ("warn", "mic off") }
//   3. Once the menu-bar item has its menu, hand it over so the app can live in Nexus's menu:
//          NexusBeacon.attach(item)
//
// It writes ~/.nexus/heartbeats/<bundleid>.json every 30s and a final "offline" beat on quit.
// After `attach`, it also mirrors the item's menu to ~/.nexus/menus/<bundleid>.json whenever Nexus
// opens its own menu, runs the menu items Nexus asks for (~/.nexus/inbox/<bundleid>/), and hides
// the item while "Keep agents in Nexus" is on (~/.nexus/folder.json). Whenever Nexus isn't running
// the item shows, so the app can always be reached. There is no dependency on Nexus being installed.

import Foundation
import AppKit

enum NexusBeacon {
    private static var timer: Timer?
    private static var appName = ""
    private static var provider: (() -> (String, String))?

    /// Begins the heartbeat. `status` optionally returns ("ok"|"warn"|"error", detail) each beat.
    static func start(name: String, status: (() -> (String, String))? = nil) {
        appName = name
        provider = status
        beat()
        let t = Timer(timeInterval: 30, repeats: true) { _ in beat() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            write(status: "offline", detail: "quit")
            try? FileManager.default.removeItem(at: menuFile)
        }
    }

    static func beat() {
        let (s, d) = provider?() ?? ("ok", "")
        write(status: s, detail: d)
    }

    private static var id: String { Bundle.main.bundleIdentifier ?? "local.\(appName.lowercased())" }
    private static let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".nexus")

    private static func write(status: String, detail: String) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let dir = home.appendingPathComponent("heartbeats")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = [
            "id": id, "name": appName, "version": version,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "status": status, "detail": detail,
            "ts": Int(Date().timeIntervalSince1970),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent("\(id).json"))
        }
    }

    // MARK: Living in Nexus's menu

    private static weak var item: NSStatusItem?
    private static var inboxWatch: DispatchSourceFileSystemObject?
    private static var appsWatch: NSKeyValueObservation?
    // The parent app this app lives under, and that parent's folder settings in ~/.nexus.
    private static let nexusId = "com.stangudu.nexus"
    private static let folderFile = "folder.json"
    private static var menuFile: URL { home.appendingPathComponent("menus/\(id).json") }
    private static var inbox: URL { home.appendingPathComponent("inbox/\(id)") }

    /// Lets Nexus show this item's menu and, when asked, hide the item itself.
    static func attach(_ statusItem: NSStatusItem) {
        item = statusItem
        let fm = FileManager.default
        try? fm.createDirectory(at: menuFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let fd = open(inbox.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { readInbox() }
            src.setCancelHandler { close(fd) }
            src.resume()
            inboxWatch = src
        }
        // Nexus starting or quitting decides whether the item may hide. It's a menu-bar app, which
        // NSWorkspace's launch/quit notifications leave out, so watch the running-apps list instead.
        appsWatch = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { _, change in
            let moved = (change.newValue ?? []) + (change.oldValue ?? [])
            if moved.contains(where: { $0.bundleIdentifier == nexusId }) { DispatchQueue.main.async { applyFolder() } }
        }
        readInbox()
        applyFolder()
        dumpMenu()
    }

    /// Shows or hides the item: hidden only while Nexus runs with "Keep agents in Nexus" on and
    /// this app isn't on its "keep in menu bar" list.
    private static func applyFolder() {
        guard let item else { return }
        let cfg = (try? Data(contentsOf: home.appendingPathComponent(folderFile)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let on = cfg["enabled"] as? Bool ?? false
        let shown = cfg["shown"] as? [String] ?? []
        let nexusUp = NSRunningApplication.runningApplications(withBundleIdentifier: nexusId).contains { !$0.isTerminated }
        item.isVisible = !(on && nexusUp && !shown.contains(id))
    }

    private static func readInbox() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            let cmd = (try? Data(contentsOf: f)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            try? fm.removeItem(at: f)
            switch cmd?["cmd"] as? String {
            case "dump": dumpMenu()
            case "folder": applyFolder()
            case "perform":
                if let path = cmd?["path"] as? [Int] { perform(path, title: cmd?["title"] as? String ?? "") }
            default: break
            }
        }
    }

    /// Lets each menu fill itself in, the way it would when opened.
    private static func prepare(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }

    /// The menu as JSON: each entry is a separator or {t: title, e: enabled, s: on, k: [submenu]}.
    private static func dumpMenu() {
        guard let menu = item?.menu else { return }
        func entries(_ m: NSMenu) -> [[String: Any]] {
            prepare(m)
            return m.items.enumerated().compactMap { i, it in
                if it.isHidden || it.isAlternate { return nil }
                if it.isSeparatorItem { return ["i": i, "sep": true] }
                var e: [String: Any] = ["i": i, "t": it.title, "e": it.isEnabled, "s": it.state == .on]
                if let sub = it.submenu { e["k"] = entries(sub) }
                return e
            }
        }
        let obj: [String: Any] = ["id": id, "name": appName, "ts": Int(Date().timeIntervalSince1970), "items": entries(menu)]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: menuFile, options: .atomic) }
    }

    /// Runs the menu item at `path` (indexes into each level), checking the title still matches in
    /// case the menu changed since Nexus read it; if not, the item with that title on the last level.
    private static func perform(_ path: [Int], title: String) {
        guard var menu = item?.menu, !path.isEmpty else { return }
        for i in path.dropLast() {
            prepare(menu)
            guard i < menu.items.count, let sub = menu.items[i].submenu else { return }
            menu = sub
        }
        prepare(menu)
        var i = path.last!
        if i >= menu.items.count || menu.items[i].title != title {
            guard let j = menu.items.firstIndex(where: { $0.title == title }) else { return }
            i = j
        }
        guard menu.items[i].isEnabled else { return }
        NSApp.activate(ignoringOtherApps: true)
        menu.performActionForItem(at: i)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { dumpMenu() }
    }
}

// FleetStyles — the design style each personal app wears, picked in the app's own Settings or in Nexus ›
// 🎨 Style per app, and the same in both: a pick in either shows in the other within seconds.
//
// Master copy: ~/Nexus/styles/FleetStyles.swift. scripts/sync-styles.sh copies it into the apps that have styles
// (SWIFT_APPS there); don't edit the copies. Electron apps get the same thing in styles/fleet-styles-node.js.
//
// ~/.nexus/styles.json, one entry per app by bundle id:
//   { "apps": { "<bundle id>": { "app": "Idea Forge", "style": "clay", "styles": [{ "id", "name", "blurb" }…],
//               "updated": "<ISO date>" } } }
// Both sides write it, one app's entry at a time (read, change, write, holding styles.lock so an app and Nexus
// saving at once don't undo each other).
//
//   In an app   FleetStyles.start(app:) at launch (declares FleetStyles.all, settles the pick, follows picks made in
//               Nexus), FleetStyles.wear(web) for every WKWebView that wears the style, FleetStyles.choose(id) when
//               Settings picks one, and FleetStyles.pick / FleetStyles.list for the Settings page's state. The pick
//               is kept in the app's own UserDefaults ("uiStyle"), so it holds without Nexus too.
//               (Lower down: declare(app:styles:current:), set(_:), watch { … }, current().)
//   In Nexus    FleetStyles.apps() lists them; FleetStyles.set(_:for:) picks for one.
//
// The pages draw the styles with the fleet styles kit (styles/fleet-styles.css + .js, pasted in by sync-styles.sh).
// Without Nexus nothing is read or written, and the app's own setting is all there is.

import Foundation
import WebKit
import AppKit

enum FleetStyles {
    struct Style {
        let id: String, name: String, blurb: String
        init(_ id: String, _ name: String, _ blurb: String) { self.id = id; self.name = name; self.blurb = blurb }
    }

    // MARK: The kit

    /// The 14 styles the fleet styles kit draws, in Settings order.
    static let all: [Style] = [
        .init("standard", "Standard", "The app's usual look."),
        .init("skeuo", "Skeuomorphic", "Real things: linen, stitched paper, brushed metal, glossy buttons."),
        .init("flat", "Flat", "No depth: solid colours, no shadows, small corners."),
        .init("material", "Material", "Paper layers with shadows, underlined tabs, uppercase buttons."),
        .init("neumorph", "Neumorphic", "Soft UI: shapes pushed out of, or pressed into, the page."),
        .init("glass", "Glassmorphism", "Frosted see-through panes over a colourful backdrop."),
        .init("liquid", "Liquid Glass", "Clear glass with bright rims, an inner glow and capsule controls."),
        .init("clay", "Claymorphism", "Puffy pastel clay shapes and rounded type."),
        .init("brutal", "Neo-brutalism", "Thick black outlines, hard shadows, loud flat fills."),
        .init("swiss", "Swiss minimal", "Rules and type instead of boxes: black, white and one red."),
        .init("bento", "Bento grid", "Big rounded tiles in mixed tints, big numbers."),
        .init("retro", "Retro", "A Windows 95 desktop: bevelled grey windows, blue title bars."),
        .init("aurora", "Aurora", "Soft colour glows behind clean cards, gradient accents."),
        .init("cyber", "Cyber", "Neon edges on near-black, mono type, faint scan lines."),
    ]
    private static var offered = all
    private static let pages = NSHashTable<WKWebView>.weakObjects()

    /// The style this app wears (its own setting; a pick in Nexus lands here too).
    static var pick: String {
        get { let v = UserDefaults.standard.string(forKey: "uiStyle") ?? "standard"; return offered.contains { $0.id == v } ? v : "standard" }
        set { UserDefaults.standard.set(newValue, forKey: "uiStyle") }
    }
    /// The styles on offer, for the Settings page: [{ id, name, blurb }].
    static var list: [[String: String]] { offered.map { ["id": $0.id, "name": $0.name, "blurb": $0.blurb] } }

    /// Call once at launch. `changed` runs after a pick made in Nexus is put on, e.g. to refresh an open Settings.
    static func start(app: String, styles: [Style] = all, changed: (() -> Void)? = nil) {
        offered = styles
        pick = declare(app: app, styles: styles, current: pick)
        watch {
            guard let s = current(), offered.contains(where: { $0.id == s }), s != pick else { return }
            pick = s
            redress()
            changed?()
        }
    }

    /// The user picked a style in the app's Settings: wear it, and Nexus shows it too.
    static func choose(_ id: String) {
        guard offered.contains(where: { $0.id == id }), id != pick else { return }
        pick = id
        set(id)
        redress()
    }

    /// A page that wears the style: <html data-style> now, and on every page it loads later (before it draws).
    static func wear(_ web: WKWebView) {
        pages.add(web)
        dress(web)
    }
    private static func dress(_ web: WKWebView) {
        let js = "document.documentElement.setAttribute('data-style', '\(pick)')"     // ids are plain words
        web.configuration.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.evaluateJavaScript(js, completionHandler: nil)
    }
    private static func redress() { pages.allObjects.forEach(dress) }

    /// ~/.nexus, Nexus's own folder (made here if Nexus hasn't run yet).
    private static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nexus")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Nexus is on this Mac (or this is Nexus).
    static var parentInstalled: Bool {
        Bundle.main.bundleIdentifier == "com.stangudu.nexus"
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stangudu.nexus") != nil
    }
    static var url: URL { dir.appendingPathComponent("styles.json") }
    private static var lockURL: URL { dir.appendingPathComponent("styles.lock") }
    private static var appId: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    // MARK: In an app

    /// Records the styles this app offers and settles which is on. Call at launch; returns the style to wear.
    @discardableResult
    static func declare(app: String, styles: [Style], current: String) -> String {
        guard parentInstalled else { return current }
        let ids = styles.map(\.id)
        var wear = current
        update { apps in
            var e = apps[appId] ?? [:]
            if let s = e["style"] as? String, ids.contains(s) { wear = s }      // picked in Nexus while we were closed
            e["app"] = app
            e["style"] = wear
            e["styles"] = styles.map { ["id": $0.id, "name": $0.name, "blurb": $0.blurb] }
            apps[appId] = e
        }
        return wear
    }

    /// The user picked a style in the app: Nexus shows it too.
    static func set(_ style: String) {
        guard parentInstalled else { return }
        update { apps in
            guard var e = apps[appId] else { return }
            e["style"] = style
            apps[appId] = e
        }
    }

    /// This app's style in the file (it may have been picked in Nexus), or nil without Nexus or an entry.
    static func current() -> String? {
        guard parentInstalled else { return nil }
        return read()[appId]?["style"] as? String
    }

    // MARK: In Nexus

    /// Every app that has declared its styles, by name.
    static func apps() -> [[String: Any]] {
        read().map { id, e in e.merging(["id": id]) { a, _ in a } }
            .sorted { ($0["app"] as? String ?? "") < ($1["app"] as? String ?? "") }
    }

    /// Picks a style for one app. Only one it declared is taken.
    static func set(_ style: String, for id: String) {
        update { apps in
            guard var e = apps[id], (e["styles"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == style }) else { return }
            e["style"] = style
            apps[id] = e
        }
    }

    // MARK: The file

    private static var watchers: [() -> Void] = []
    private static var timer: Timer?
    private static var lastStamp: Date?

    /// Calls `handler` on the main thread whenever styles.json changes (checked every 3 s).
    static func watch(_ handler: @escaping () -> Void) {
        watchers.append(handler)
        guard timer == nil else { return }
        lastStamp = stamp()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            let s = stamp()
            guard s != lastStamp else { return }
            lastStamp = s
            watchers.forEach { $0() }
        }
    }
    private static func stamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func read() -> [String: [String: Any]] {
        let doc = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return doc?["apps"] as? [String: [String: Any]] ?? [:]
    }

    /// Read, change, write, holding the lock file. An entry that changed gets a new "updated".
    private static func update(_ change: (inout [String: [String: Any]]) -> Void) {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        let before = read()
        var apps = before
        change(&apps)
        for (id, e) in apps where !NSDictionary(dictionary: e).isEqual(to: before[id] ?? [:]) {
            apps[id]?["updated"] = ISO8601DateFormatter().string(from: Date())
        }
        guard !NSDictionary(dictionary: apps).isEqual(to: before),
              let data = try? JSONSerialization.data(withJSONObject: ["apps": apps], options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

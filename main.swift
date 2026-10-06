// Nexus — the head of the fleet. A menu-bar app that watches every other app you've built
// (and any you build later), showing a live green/amber/red status for each, plus a full
// dashboard window with per-app cards and controls (open, rebuild, stop, reveal).
//
// The monitoring engine lives in Fleet.swift. This file is the menu bar, the dashboard window,
// the per-app actions, and the refresh loop that keeps both views current.

import AppKit
import WebKit
import ServiceManagement

// MARK: - Settings

/// The dashboard visualisations the user can pick from, in menu order.
/// "Operations Center" is the flagship: a full command-centre view of the fleet.
let STYLES: [(id: String, label: String)] = [
    ("opcenter",      "Operations Center"),
    ("office",        "Animated Office"),
    ("constellation", "Constellation"),
    ("city",          "Fleet City"),
    ("noc",           "Control Room"),
    ("terminal",      "Terminal"),
    ("grid",          "Status Grid"),
]

enum Settings {
    private static let d = UserDefaults.standard

    static var style: String {
        get { d.string(forKey: "dashboardStyle") ?? "opcenter" }
        set { d.set(newValue, forKey: "dashboardStyle") }
    }
    static func label(_ id: String) -> String { STYLES.first { $0.id == id }?.label ?? id }

    // MARK: Voice

    /// Whether Nexus listens for its wake word and runs spoken fleet commands.
    static var voiceEnabled: Bool {
        get { d.bool(forKey: "voiceEnabled") }
        set { d.set(newValue, forKey: "voiceEnabled") }
    }

    /// The wake words Nexus answers to. First is primary; the user can add their own.
    static var wakeNames: [String] {
        get {
            if let names = d.stringArray(forKey: "wakeNames")?.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               !names.isEmpty { return names }
            return ["Nexus"]
        }
        set {
            let cleaned = newValue.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            d.set(cleaned.isEmpty || cleaned == ["Nexus"] ? nil : cleaned, forKey: "wakeNames")
        }
    }

    /// After Nexus replies, keep listening for a follow-up command without the wake word.
    static var conversation: Bool {
        get { d.object(forKey: "conversation") as? Bool ?? true }
        set { d.set(newValue, forKey: "conversation") }
    }

    /// Speech-recognition locale (e.g. "en-US"); nil means auto-detect.
    static var speechLocale: String? {
        get { d.string(forKey: "speechLocale") }
        set { d.set(newValue, forKey: "speechLocale") }
    }

    /// Preferred TTS voice identifier; nil means best available English voice.
    static var voice: String? {
        get { d.string(forKey: "voiceId") }
        set { d.set(newValue, forKey: "voiceId") }
    }

    /// Use the local Claude CLI to understand natural phrasing the keyword parser can't (on by default).
    static var brain: Bool {
        get { d.object(forKey: "brain") as? Bool ?? true }
        set { d.set(newValue, forKey: "brain") }
    }

    /// Model for the brain; small and fast by default.
    static var brainModel: String {
        get { d.string(forKey: "brainModel") ?? "haiku" }
        set { d.set(newValue, forKey: "brainModel") }
    }

    /// Resumed Claude conversation id, so the brain keeps context across questions.
    static var brainSessionId: String? {
        get { d.string(forKey: "brainSessionId") }
        set { d.set(newValue, forKey: "brainSessionId") }
    }

    // MARK: Orb

    /// A floating Jarvis-style orb that reacts to the voice state.
    static var showOrb: Bool {
        get { d.object(forKey: "showOrb") as? Bool ?? false }
        set { d.set(newValue, forKey: "showOrb") }
    }

    /// Orb animation; one of the STYLES in orb.html.
    static var orbStyle: String {
        get { d.string(forKey: "orbStyle") ?? "reactor" }
        set { d.set(newValue, forKey: "orbStyle") }
    }

    /// Where the user last parked the orb on screen.
    static var orbOrigin: NSPoint? {
        get { d.string(forKey: "orbOrigin").map { NSPointFromString($0) } }
        set { d.set(newValue.map { NSStringFromPoint($0) }, forKey: "orbOrigin") }
    }
}

// MARK: - Per-app actions

enum Actions {
    static func open(_ app: AppInfo) {
        if let bundle = app.bundlePath {
            NSWorkspace.shared.open(URL(fileURLWithPath: bundle))
        } else if app.kind == "electron" {
            run("/usr/bin/env", ["npm", "start"], cwd: app.dir, detached: true)
        } else {
            reveal(app)
        }
    }

    static func stop(_ app: AppInfo) {
        for ra in NSWorkspace.shared.runningApplications where ra.bundleIdentifier == app.id {
            ra.terminate()
        }
        if let b = app.beat, b.pid > 0 { kill(pid_t(b.pid), SIGTERM) }
    }

    static func reveal(_ app: AppInfo) {
        NSWorkspace.shared.selectFile(app.bundlePath ?? app.dir, inFileViewerRootedAtPath: app.dir)
    }

    /// Rebuilds in the background, logging to ~/.nexus/logs, and flips the app's transient state.
    static func build(_ app: AppInfo, done: @escaping () -> Void) {
        guard !app.building else { return }
        app.building = true; app.buildResult = nil; done()
        let cmd: (String, [String])
        if app.kind == "electron" { cmd = ("/usr/bin/env", ["npm", "run", "dist"]) }
        else { cmd = ("/bin/bash", ["build.sh"]) }
        let log = (NexusHome.logs as NSString).appendingPathComponent("\(app.id)-build.log")

        DispatchQueue.global(qos: .utility).async {
            FileManager.default.createFile(atPath: log, contents: nil)
            let handle = FileHandle(forWritingAtPath: log)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cmd.0)
            p.arguments = cmd.1
            p.currentDirectoryURL = URL(fileURLWithPath: app.dir)
            if let handle { p.standardOutput = handle; p.standardError = handle }
            let ok: Bool
            do { try p.run(); p.waitUntilExit(); ok = p.terminationStatus == 0 }
            catch { ok = false }
            handle?.closeFile()
            DispatchQueue.main.async {
                app.building = false
                app.buildResult = ok ? "built just now" : "build failed — see log"
                done()
            }
        }
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String], cwd: String, detached: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        do { try p.run(); if !detached { p.waitUntilExit() }; return true } catch { return false }
    }
}

// MARK: - Dashboard window

final class Dashboard: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var window: NSWindow?
    private var web: WKWebView?
    private var loaded = false
    var onAction: ((String, String) -> Void)?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Nexus"
        w.titleVisibility = .hidden            // keep a draggable titlebar, but no title text
        w.titlebarAppearsTransparent = true    // let the dark page show through for a seamless look
        w.backgroundColor = NSColor(red: 7/255, green: 10/255, blue: 18/255, alpha: 1)  // matches --bg0
        w.isMovableByWindowBackground = true
        w.center()
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 480)

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "nexus")
        let wv = WKWebView(frame: w.contentView!.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        if let html = Bundle.main.url(forResource: "dashboard", withExtension: "html") {
            wv.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        w.contentView?.addSubview(wv)
        window = w; web = wv
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    var isOpen: Bool { window?.isVisible == true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        push()
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String], let action = body["action"] else { return }
        onAction?(action, body["id"] ?? "")
    }

    /// Serialises the fleet to JSON and hands it to the page.
    func push() {
        guard loaded, let web else { return }
        let apps: [[String: Any]] = Fleet.shared.apps.map { a in
            [
                "id": a.id, "name": a.name, "kind": a.kind,
                "status": a.status.word, "key": a.status.key, "color": a.status.hex, "dot": a.status.dot,
                "version": a.version, "detail": a.detail,
                "running": a.status.severity == 1 || a.status == .stale,
                "installed": a.installed, "dir": a.dir,
            ]
        }
        let summary: [String: Any] = [
            "total": Fleet.shared.apps.count,
            "running": Fleet.shared.runningCount,
            "worst": Fleet.shared.worst.hex,
        ]
        let payload: [String: Any] = ["apps": apps, "summary": summary, "style": Settings.style]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("render(\(json))")
    }
}

// MARK: - Voice orb

/// The orb's web view — drag to move, click (without moving) to start listening.
final class OrbView: WKWebView {
    var onClick: (() -> Void)?
    var contextMenu: NSMenu?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let start = NSEvent.mouseLocation, origin = win.frame.origin
        var moved = false
        while let ev = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), ev.type == .leftMouseDragged {
            let p = NSEvent.mouseLocation
            if abs(p.x - start.x) + abs(p.y - start.y) > 3 { moved = true }
            win.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
        }
        if moved { Settings.orbOrigin = win.frame.origin } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let contextMenu { NSMenu.popUpContextMenu(contextMenu, with: event, for: self) }
    }
}

/// A borderless floating panel hosting the orb, mirroring Jarvis. It reflects the current
/// voice state (idle / listening / working / speaking / off), mic level, and spoken captions.
final class OrbPanel: NSObject, WKNavigationDelegate {
    private var panel: NSPanel?
    private var web: OrbView?
    private var ready = false
    private var state = "off", caption = ""
    private var fleetTotal = 0, fleetRunning = 0
    var onClick: (() -> Void)?
    var contextMenu: NSMenu?

    private func build() {
        guard panel == nil else { return }
        let size = NSSize(width: 240, height: 280)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let v = OrbView(frame: NSRect(origin: .zero, size: size), configuration: WKWebViewConfiguration())
        v.setValue(false, forKey: "drawsBackground")
        v.navigationDelegate = self
        v.onClick = { [weak self] in self?.onClick?() }
        v.contextMenu = contextMenu
        p.contentView = v
        if let url = Bundle.main.url(forResource: "orb", withExtension: "html") {
            v.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        if let o = Settings.orbOrigin, NSScreen.screens.contains(where: { $0.frame.contains(o) }) {
            p.setFrameOrigin(o)
        } else if let vf = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 20, y: vf.minY + 20))
        }
        panel = p; web = v
    }

    var visible: Bool { panel?.isVisible == true }

    func show() { build(); panel?.orderFrontRegardless() }
    func hide() { panel?.orderOut(nil) }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        ready = true
        js("setStyle('\(Settings.orbStyle)')")
        js("setState('\(state)')")
        js("setFleet(\(fleetTotal),\(fleetRunning))")
        if !caption.isEmpty { js("setCaption(\(App.jsString(caption)))") }
    }

    func setState(_ s: String) { state = s; js("setState('\(s)')") }
    func setLevel(_ l: Float)  { js("setLevel(\(l))") }
    func setStyle(_ s: String) { js("setStyle('\(s)')") }
    func setCaption(_ t: String) { caption = t; js("setCaption(\(App.jsString(t)))") }
    func setFleet(_ total: Int, _ running: Int) {
        fleetTotal = total; fleetRunning = running
        js("setFleet(\(total),\(running))")
    }

    private func js(_ code: String) { if ready, let web { web.evaluateJavaScript(code) } }
}

// MARK: - Settings window

/// A panel for the dashboard style plus voice control: the wake words Nexus answers to,
/// the recognition accent, and launch-at-login. Mirrors the menu-bar toggles.
final class SettingsWindow: NSObject, NSTokenFieldDelegate {
    private var window: NSWindow?
    private var popup: NSPopUpButton?
    private var voiceCheck: NSButton?
    private var loginCheck: NSButton?
    private var namesField: NSTokenField?
    private var localePopup: NSPopUpButton?
    var onChange: (() -> Void)?        // dashboard style changed
    var onVoiceChange: (() -> Void)?   // voice enabled / wake names / locale changed

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            sync()
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 440),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Nexus Settings"
        w.center()
        w.isReleasedWhenClosed = false

        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        var views: [NSView] = []

        // --- Dashboard style -------------------------------------------------
        views.append(label("Dashboard Style", frame: NSRect(x: 24, y: 400, width: 392, height: 22), size: 15, bold: true))
        let styleHint = label("How the fleet is visualised in the dashboard window.",
                              frame: NSRect(x: 24, y: 380, width: 392, height: 16), size: 11, bold: false)
        styleHint.textColor = .secondaryLabelColor
        views.append(styleHint)

        let pop = NSPopUpButton(frame: NSRect(x: 24, y: 346, width: 392, height: 28))
        for s in STYLES { pop.addItem(withTitle: s.label) }
        pop.target = self; pop.action = #selector(pickStyle(_:))
        popup = pop; views.append(pop)

        // --- Voice control ---------------------------------------------------
        views.append(separator(y: 326))
        views.append(label("Voice Control", frame: NSRect(x: 24, y: 292, width: 392, height: 22), size: 15, bold: true))

        let vc = NSButton(checkboxWithTitle: "  Listen for the wake word and run spoken commands",
                          target: self, action: #selector(toggleVoice(_:)))
        vc.frame = NSRect(x: 24, y: 262, width: 392, height: 22)
        voiceCheck = vc; views.append(vc)

        views.append(label("Wake words", frame: NSRect(x: 24, y: 230, width: 392, height: 18), size: 12, bold: true))
        let namesHint = label("Say any of these to get Nexus's attention. Add your own — press return after each.",
                              frame: NSRect(x: 24, y: 212, width: 392, height: 16), size: 11, bold: false)
        namesHint.textColor = .secondaryLabelColor
        views.append(namesHint)

        let names = NSTokenField(frame: NSRect(x: 24, y: 178, width: 392, height: 26))
        names.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
        names.delegate = self
        names.target = self; names.action = #selector(commitNames(_:))
        namesField = names; views.append(names)

        views.append(label("Recognition accent", frame: NSRect(x: 24, y: 146, width: 392, height: 18), size: 12, bold: true))
        let lp = NSPopUpButton(frame: NSRect(x: 24, y: 112, width: 392, height: 28))
        lp.addItem(withTitle: "Automatic")
        lp.item(at: 0)?.representedObject = ""
        for (id, name) in Ears.accents {
            lp.addItem(withTitle: name)
            lp.item(at: lp.numberOfItems - 1)?.representedObject = id
        }
        lp.target = self; lp.action = #selector(pickLocale(_:))
        localePopup = lp; views.append(lp)

        // --- Launch at login -------------------------------------------------
        views.append(separator(y: 92))
        let login = NSButton(checkboxWithTitle: "  Launch Nexus at login",
                             target: self, action: #selector(toggleLogin(_:)))
        login.frame = NSRect(x: 24, y: 58, width: 392, height: 22)
        loginCheck = login; views.append(login)

        let loginNote = label("Nexus wakes the other agents on command, so only Nexus needs a login item.",
                              frame: NSRect(x: 44, y: 36, width: 372, height: 16), size: 11, bold: false)
        loginNote.textColor = .tertiaryLabelColor
        views.append(loginNote)

        for v in views { content.addSubview(v) }
        w.contentView = content
        window = w
        sync()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func sync() {
        if let i = STYLES.firstIndex(where: { $0.id == Settings.style }) { popup?.selectItem(at: i) }
        voiceCheck?.state = Settings.voiceEnabled ? .on : .off
        loginCheck?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        namesField?.objectValue = Settings.wakeNames
        let loc = Settings.speechLocale ?? ""
        localePopup?.selectItem(at: 0)
        for i in 0..<(localePopup?.numberOfItems ?? 0) where (localePopup?.item(at: i)?.representedObject as? String) == loc {
            localePopup?.selectItem(at: i)
        }
    }

    @objc private func pickStyle(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < STYLES.count else { return }
        Settings.style = STYLES[i].id
        onChange?()
    }

    @objc private func toggleVoice(_ sender: NSButton) {
        Settings.voiceEnabled = sender.state == .on
        onVoiceChange?()
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        let svc = SMAppService.mainApp
        do { svc.status == .enabled ? try svc.unregister() : try svc.register() }
        catch { NSLog("Nexus: launch at login: \(error)") }
        sender.state = (svc.status == .enabled) ? .on : .off
    }

    @objc private func commitNames(_ sender: NSTokenField) {
        let names = (sender.objectValue as? [String]) ?? []
        Settings.wakeNames = names
        namesField?.objectValue = Settings.wakeNames   // reflect the cleaned/defaulted list
        onVoiceChange?()
    }

    @objc private func pickLocale(_ sender: NSPopUpButton) {
        let id = (sender.selectedItem?.representedObject as? String) ?? ""
        Settings.speechLocale = id.isEmpty ? nil : id
        onVoiceChange?()
    }

    private func separator(y: CGFloat) -> NSBox {
        let box = NSBox(frame: NSRect(x: 24, y: y, width: 392, height: 1))
        box.boxType = .separator
        return box
    }

    private func label(_ text: String, frame: NSRect, size: CGFloat, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = frame
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return l
    }
}

// MARK: - App / menu bar

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let dashboard = Dashboard()
    let settingsWindow = SettingsWindow()
    let voice = Voice()
    let orb = OrbPanel()
    var voiceState = "idle"
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        NexusHome.ensure()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        dashboard.onAction = { [weak self] action, id in self?.handle(action, id) }
        settingsWindow.onChange = { [weak self] in self?.dashboard.push() }
        settingsWindow.onVoiceChange = { [weak self] in self?.applyVoiceSetting() }
        Fleet.shared.onChange = { [weak self] in self?.updateIcon(); self?.dashboard.push(); self?.pushFleetToOrb() }

        voice.showDashboard = { [weak self] in self?.dashboard.show() }
        voice.onState = { [weak self] state in
            self?.voiceState = state
            DispatchQueue.main.async { self?.orb.setState(state); self?.updateIcon() }
        }
        voice.onLevel = { [weak self] level in self?.orb.setLevel(level) }
        voice.onCaption = { [weak self] text in self?.orb.setCaption(text) }

        // The orb shares the status-bar menu on right-click and starts listening when clicked.
        orb.onClick = { [weak self] in self?.listenNow() }
        let orbMenu = NSMenu(); orbMenu.delegate = self
        orb.contextMenu = orbMenu

        Fleet.shared.discover()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }

        // Start Nexus's own beacon so it shows up in its own board.
        NexusBeacon.start(name: "Nexus") { ("ok", "watching \(Fleet.shared.apps.count) apps") }

        // Nexus is the fleet's wake-up switch: if voice is on, it listens for its name.
        if Settings.voiceEnabled { voice.start() }
        if Settings.showOrb { orb.show(); orb.setState(Settings.voiceEnabled ? "idle" : "off") }
        pushFleetToOrb()

        if CommandLine.arguments.contains("--dashboard") { dashboard.show() }
    }

    /// Click the orb to listen immediately, without the wake word.
    func listenNow() {
        // First click with voice off: enable it (it starts listening for the wake word).
        if !Settings.voiceEnabled { Settings.voiceEnabled = true; applyVoiceSetting(); return }
        // Otherwise clicking the orb is a straight toggle, exactly like Jarvis.
        voice.toggle()
    }

    static func jsString(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    /// Turns the ear on or off to match the current setting.
    func applyVoiceSetting() {
        if Settings.voiceEnabled { voice.reload(); voice.start(); orb.setState("idle") }
        else { voice.stop(); orb.setState("off") }
        updateIcon()
    }

    func tick() {
        Fleet.shared.discover()
        Fleet.shared.refresh()   // fires onChange → updates icon + dashboard
    }

    func updateIcon() {
        let worst = Fleet.shared.worst
        if let img = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                             accessibilityDescription: "Nexus") {
            img.isTemplate = false
            item.button?.image = img.withSymbolColor(worst.nsColor)
            item.button?.title = ""
        } else {
            item.button?.image = nil
            item.button?.title = worst.dot
        }
        let n = Fleet.shared.apps.count
        var tip = "Nexus — \(Fleet.shared.runningCount)/\(n) running"
        if Settings.voiceEnabled {
            switch voiceState {
            case "listening": tip += " · listening…"
            case "working":   tip += " · working…"
            default:          tip += " · voice on"
            }
        }
        item.button?.toolTip = tip
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        Fleet.shared.refresh()
        menu.removeAllItems()
        let n = Fleet.shared.apps.count
        let header = NSMenuItem(title: "Nexus — \(Fleet.shared.runningCount)/\(n) apps running", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for app in Fleet.shared.apps {
            let d = app.detail.isEmpty ? "" : " — \(app.detail)"
            let title = "\(app.status.dot)  \(app.name)  ·  \(app.status.word)\(d)"
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.submenu = submenu(for: app)
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        add(menu, "Open Dashboard…", #selector(openDashboard))

        // Dashboard Style ▸ — radio list of the available visualisations.
        let styleItem = NSMenuItem(title: "Dashboard Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for s in STYLES {
            let mi = NSMenuItem(title: s.label, action: #selector(pickStyle(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s.id
            mi.state = (Settings.style == s.id) ? .on : .off
            styleMenu.addItem(mi)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        add(menu, "Rebuild All", #selector(rebuildAll))
        add(menu, "Refresh Now", #selector(refreshNow))

        menu.addItem(.separator())

        // Voice control — Nexus listens for its wake word and runs spoken fleet commands.
        if Settings.voiceEnabled && !voice.permitted {
            // Make the status actionable: click it to jump to the right System Settings pane.
            add(menu, "⚠︎ Grant Microphone & Speech…", #selector(openVoicePrivacy))
        } else {
            let voiceStatus = NSMenuItem(title: voice.status, action: nil, keyEquivalent: "")
            voiceStatus.isEnabled = false
            menu.addItem(voiceStatus)
        }
        let voiceToggle = add(menu, "Voice Control", #selector(toggleVoice))
        voiceToggle.state = Settings.voiceEnabled ? .on : .off
        let convo = add(menu, "Conversation Mode (no wake word for follow-ups)", #selector(toggleConversation))
        convo.state = Settings.conversation ? .on : .off
        if !Settings.voiceEnabled { convo.isEnabled = false }

        // The floating orb — a Jarvis-style face that reacts to the voice state.
        let orbToggle = add(menu, "Show Orb", #selector(toggleOrb))
        orbToggle.state = Settings.showOrb ? .on : .off
        let orbItem = NSMenuItem(title: "Orb Style", action: nil, keyEquivalent: "")
        let orbMenu = NSMenu()
        for (id, title) in App.orbStyles {
            let mi = NSMenuItem(title: title, action: #selector(pickOrbStyle(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = id
            mi.state = (Settings.orbStyle == id) ? .on : .off
            orbMenu.addItem(mi)
        }
        orbItem.submenu = orbMenu
        menu.addItem(orbItem)

        // Launch at login — because Nexus wakes the other agents on command, only it needs this.
        let login = add(menu, "Launch Nexus at Login", #selector(toggleLogin))
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        add(menu, "Settings…", #selector(openSettings))
        menu.addItem(.separator())
        add(menu, "Quit Nexus", #selector(quit))
    }

    private func submenu(for app: AppInfo) -> NSMenu {
        let sub = NSMenu()
        let info = NSMenuItem(title: "\(app.name)  v\(app.version)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        sub.addItem(info)
        sub.addItem(.separator())
        let running = app.status.severity == 1 || app.status == .stale
        add(sub, running ? "Restart" : "Open", #selector(doOpen(_:)), app.id)
        if running { add(sub, "Stop", #selector(doStop(_:)), app.id) }
        add(sub, app.building ? "Building…" : "Rebuild", #selector(doBuild(_:)), app.id, enabled: !app.building)
        add(sub, "Reveal in Finder", #selector(doReveal(_:)), app.id)
        return sub
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ id: String? = nil, enabled: Bool = true) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        mi.representedObject = id
        mi.isEnabled = enabled
        menu.addItem(mi)
        return mi
    }

    // MARK: Actions

    private func app(from sender: Any?) -> AppInfo? {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String else { return nil }
        return Fleet.shared.app(id)
    }

    @objc func doOpen(_ s: NSMenuItem) { if let a = app(from: s) { if a.status.severity == 1 { Actions.stop(a); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Actions.open(a) } } else { Actions.open(a) } } }
    @objc func doStop(_ s: NSMenuItem) { if let a = app(from: s) { Actions.stop(a) } }
    @objc func doReveal(_ s: NSMenuItem) { if let a = app(from: s) { Actions.reveal(a) } }
    @objc func doBuild(_ s: NSMenuItem) { if let a = app(from: s) { Actions.build(a) { Fleet.shared.onChange?() } } }

    func handle(_ action: String, _ id: String) {
        switch action {
        case "dashboardReady": dashboard.push()
        case "refresh": tick()
        case "rebuildAll": rebuildAll()
        case "setStyle": Settings.style = id; dashboard.push()   // id carries the style id here
        default:
            guard let a = Fleet.shared.app(id) else { return }
            switch action {
            case "open": Actions.open(a)
            case "restart": Actions.stop(a); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Actions.open(a) }
            case "stop": Actions.stop(a)
            case "build": Actions.build(a) { self.dashboard.push() }
            case "reveal": Actions.reveal(a)
            default: break
            }
        }
    }

    @objc func openDashboard() { dashboard.show() }
    @objc func refreshNow() { tick() }

    @objc func pickStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.style = id
        dashboard.push()
    }
    @objc func openSettings() { settingsWindow.show() }

    @objc func toggleVoice() {
        Settings.voiceEnabled.toggle()
        applyVoiceSetting()
    }

    @objc func toggleConversation() { Settings.conversation.toggle() }

    @objc func openVoicePrivacy() { Voice.openPrivacySettings() }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do { svc.status == .enabled ? try svc.unregister() : try svc.register() }
        catch { NSLog("Nexus: launch at login: \(error)") }
    }

    static let orbStyles = [("reactor", "Arc Reactor"), ("pulse", "Pulse"), ("waveform", "Waveform"),
                            ("particles", "Particles"), ("gyroscope", "Gyroscope"), ("fleet", "Fleet")]

    @objc func toggleOrb() {
        Settings.showOrb.toggle()
        if Settings.showOrb { orb.show(); orb.setState(Settings.voiceEnabled ? voiceState : "off"); pushFleetToOrb() }
        else { orb.hide() }
    }

    /// Mirrors the dashboard's agent counts onto the orb's `fleet` style: total discovered agents
    /// and how many are active (same running tally the dashboard header shows).
    func pushFleetToOrb() {
        orb.setFleet(Fleet.shared.apps.count, Fleet.shared.runningCount)
    }

    @objc func pickOrbStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.orbStyle = id
        orb.setStyle(id)
        if !Settings.showOrb { toggleOrb() }
    }

    @objc func rebuildAll() {
        for a in Fleet.shared.apps where a.installed && !a.building {
            Actions.build(a) { self.dashboard.push() }
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Symbol tint helper

extension NSImage {
    func withSymbolColor(_ color: NSColor) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(paletteColors: [color])
        return self.withSymbolConfiguration(cfg) ?? self
    }
}

// Headless text view of the fleet — `Nexus --probe` — for scripting and quick checks.
if CommandLine.arguments.contains("--probe") {
    NexusHome.ensure()
    Fleet.shared.discover()
    Fleet.shared.refresh()
    print("Nexus — \(Fleet.shared.runningCount)/\(Fleet.shared.apps.count) running\n")
    for a in Fleet.shared.apps {
        let d = a.detail.isEmpty ? "" : " — \(a.detail)"
        print("\(a.status.dot) \(a.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(a.status.word)\(d)  [\(a.kind) v\(a.version)]")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

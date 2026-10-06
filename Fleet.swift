// Nexus — the fleet engine. Discovers every app in the home folder, reads their heartbeats,
// inspects running processes, and computes a single health status per app.
//
// Discovery is automatic: any sibling folder that looks like one of these apps (a Swift app
// built by build.sh, or an Electron app) is picked up with zero configuration, so apps created
// in the future appear here the moment they exist. The optional ~/.nexus/apps.json can add apps
// that live outside the home folder or override a name.
//
// The "mechanism" that lets Nexus see *inside* a running app is the heartbeat: each app drops a
// small JSON file in ~/.nexus/heartbeats/<bundleid>.json every 30s via NexusBeacon (Swift) or
// nexus-beacon.js (Electron). Nexus reads those files to know an app is alive, which version is
// running, and whether the app considers itself ok / warn / error. No ports, no servers, no network.

import AppKit
import Darwin

// MARK: - Shared locations

enum NexusHome {
    static let root = (NSHomeDirectory() as NSString).appendingPathComponent(".nexus")
    static let heartbeats = (root as NSString).appendingPathComponent("heartbeats")
    static let logs = (root as NSString).appendingPathComponent("logs")
    static let config = (root as NSString).appendingPathComponent("apps.json")

    static func ensure() {
        for d in [root, heartbeats, logs] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Heartbeat

/// One heartbeat as written by a monitored app.
struct Beat {
    let name: String
    let version: String
    let pid: Int
    let status: String      // "ok" | "warn" | "error" | "offline"
    let detail: String
    let ts: Date

    var age: TimeInterval { Date().timeIntervalSince(ts) }
    var fresh: Bool { age < 90 }

    static func read(_ path: String) -> Beat? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Beat(
            name: obj["name"] as? String ?? "",
            version: obj["version"] as? String ?? "?",
            pid: (obj["pid"] as? Int) ?? Int((obj["pid"] as? Double) ?? 0),
            status: (obj["status"] as? String ?? "ok").lowercased(),
            detail: obj["detail"] as? String ?? "",
            ts: Date(timeIntervalSince1970: (obj["ts"] as? Double) ?? Double((obj["ts"] as? Int) ?? 0))
        )
    }
}

// MARK: - Health

enum Status: Int, Comparable {
    // Raw value is sort priority — lower sorts first (more urgent).
    case error = 0, crashed = 1, stale = 2, warn = 3, needsBuild = 4, building = 5
    case running = 6, idle = 7, notBuilt = 8

    static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

    var severity: Int {   // 3 red, 2 amber, 1 green, 0 neutral
        switch self {
        case .error, .crashed: return 3
        case .stale, .warn, .needsBuild: return 2
        case .running: return 1
        case .building, .idle, .notBuilt: return 0
        }
    }

    var hex: String {   // for the dashboard
        switch severity {
        case 3: return "#ff4d5e"
        case 2: return "#ffb020"
        case 1: return "#2ecc71"
        default: return self == .building ? "#4a9eff" : "#6b7280"
        }
    }

    var nsColor: NSColor {
        switch severity {
        case 3: return .systemRed
        case 2: return .systemOrange
        case 1: return .systemGreen
        default: return self == .building ? .systemBlue : .secondaryLabelColor
        }
    }

    var dot: String {
        switch severity {
        case 3: return "🔴"
        case 2: return "🟡"
        case 1: return "🟢"
        default: return self == .building ? "🔵" : "⚪"
        }
    }

    var key: String {
        switch self {
        case .error: return "error"
        case .crashed: return "crashed"
        case .stale: return "stale"
        case .warn: return "warn"
        case .needsBuild: return "needsBuild"
        case .building: return "building"
        case .running: return "running"
        case .idle: return "idle"
        case .notBuilt: return "notBuilt"
        }
    }

    var word: String {
        switch self {
        case .error: return "Error"
        case .crashed: return "Crashed"
        case .stale: return "Not responding"
        case .warn: return "Warning"
        case .needsBuild: return "Needs rebuild"
        case .building: return "Building…"
        case .running: return "Running"
        case .idle: return "Idle"
        case .notBuilt: return "Not built"
        }
    }
}

// MARK: - App

final class AppInfo {
    let id: String          // bundle identifier (stable key, also the heartbeat filename)
    let name: String
    let dir: String
    let kind: String        // "swift" | "electron"
    let bundlePath: String? // the .app, when built

    var beat: Beat?
    var running = false
    var needsBuild = false
    var building = false
    var buildResult: String?    // transient note after a build finishes

    init(id: String, name: String, dir: String, kind: String, bundlePath: String?) {
        self.id = id; self.name = name; self.dir = dir; self.kind = kind; self.bundlePath = bundlePath
    }

    var installed: Bool { bundlePath != nil || (kind == "electron" && FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("node_modules"))) }

    var status: Status {
        if building { return .building }
        let runningNow = running || pidAlive
        if let b = beat {
            if b.fresh {
                switch b.status {
                case "error": return .error
                case "warn": return .warn
                case "offline": return needsBuild ? .needsBuild : .idle
                default: return .running
                }
            }
            // Stale heartbeat.
            if b.status == "offline" { return needsBuild ? .needsBuild : .idle }   // clean quit
            if runningNow { return .stale }                                        // alive but not beating → hung
            return .crashed                                                        // vanished without a clean quit
        }
        // No beacon integrated.
        if runningNow { return .running }
        if !installed { return .notBuilt }
        return needsBuild ? .needsBuild : .idle
    }

    var version: String {
        if let b = beat, b.fresh, b.version != "?" { return b.version }
        return bundleVersion ?? "—"
    }

    private var bundleVersion: String? {
        guard let p = bundlePath,
              let d = NSDictionary(contentsOfFile: (p as NSString).appendingPathComponent("Contents/Info.plist")) else { return nil }
        return d["CFBundleShortVersionString"] as? String
    }

    private var pidAlive: Bool {
        guard let b = beat, b.pid > 0 else { return false }
        return kill(pid_t(b.pid), 0) == 0
    }

    var detail: String {
        if building { return "building…" }
        if let r = buildResult { return r }
        if let b = beat, b.fresh, !b.detail.isEmpty { return b.detail }
        switch status {
        case .crashed: return "last seen \(Fleet.ago(beat?.ts))"
        case .stale: return "no heartbeat for \(Fleet.ago(beat?.ts))"
        case .running: return beat != nil ? "healthy" : "running (no beacon)"
        case .needsBuild: return "sources changed since last build"
        case .notBuilt: return "run build.sh to create the app"
        case .idle: return beat != nil ? "last seen \(Fleet.ago(beat?.ts))" : "not running"
        default: return ""
        }
    }
}

// MARK: - Fleet

final class Fleet {
    static let shared = Fleet()
    private(set) var apps: [AppInfo] = []
    var onChange: (() -> Void)?

    private let home = NSHomeDirectory()
    private let skip: Set<String> = ["Nexus", "Library", "Applications", "Desktop", "Documents",
                                     "Downloads", "Movies", "Music", "Pictures", "Public", "Developer"]

    /// Rebuilds the list of apps from disk. Cheap enough to call on every refresh so new apps appear live.
    func discover() {
        var found: [String: AppInfo] = [:]
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        for entry in dirs where !entry.hasPrefix(".") && !skip.contains(entry) {
            let dir = (home as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let app = inspect(dir: dir, folder: entry) else { continue }
            found[app.id] = app
        }
        for app in configApps() { found[app.id] = app }
        apps = found.values.sorted { ($0.status, $0.name.lowercased()) < ($1.status, $1.name.lowercased()) }
    }

    /// Reads heartbeats + running processes + build freshness for the current app list.
    func refresh() {
        let beats = readBeats()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        for app in apps {
            app.beat = beats[app.id]
            app.running = running.contains(app.id)
            app.needsBuild = computeNeedsBuild(app)
        }
        apps.sort { ($0.status, $0.name.lowercased()) < ($1.status, $1.name.lowercased()) }
        onChange?()
    }

    func app(_ id: String) -> AppInfo? { apps.first { $0.id == id } }

    var worst: Status { apps.map(\.status).min() ?? .idle }
    var runningCount: Int { apps.filter { $0.status.severity == 1 || ($0.status == .stale) }.count }

    // MARK: Discovery helpers

    private func inspect(dir: String, folder: String) -> AppInfo? {
        let fm = FileManager.default
        let bundle = findBundle(in: dir)
        let hasBuild = fm.fileExists(atPath: (dir as NSString).appendingPathComponent("build.sh"))
        let pkgPath = (dir as NSString).appendingPathComponent("package.json")
        let pkg = NSDictionary(contentsOfFile: pkgPath) ?? parseJSON(pkgPath)
        let isElectron = pkg != nil && jsonMentionsElectron(pkgPath)
        guard bundle != nil || hasBuild || isElectron else { return nil }

        let kind = isElectron ? "electron" : "swift"
        // Electron apps are keyed by their package name (matches the beacon id); a packaged .app's
        // bundle id would differ and break heartbeat matching, so only read it for Swift apps.
        let id: String
        if isElectron {
            id = "local.\((pkg?["name"] as? String) ?? folder.lowercased())"
        } else {
            id = bundleID(bundle: bundle, buildSh: (dir as NSString).appendingPathComponent("build.sh"),
                          pkg: pkg, folder: folder)
        }
        let name = displayName(bundle: bundle, pkg: pkg, folder: folder)
        return AppInfo(id: id, name: name, dir: dir, kind: kind, bundlePath: bundle)
    }

    /// Finds a built `.app`, whether it sits at the top level or (as T-Minus and electron-builder
    /// do) under build/ or dist/. Prefers the top-level copy, then build/, then dist/ and its arch
    /// subfolders.
    private func findBundle(in dir: String) -> String? {
        let fm = FileManager.default
        func app(in d: String) -> String? {
            ((try? fm.contentsOfDirectory(atPath: d)) ?? []).first { $0.hasSuffix(".app") }
                .map { (d as NSString).appendingPathComponent($0) }
        }
        if let a = app(in: dir) { return a }
        for sub in ["build", "dist"] {
            let s = (dir as NSString).appendingPathComponent(sub)
            if let a = app(in: s) { return a }
            for arch in (try? fm.contentsOfDirectory(atPath: s)) ?? [] {   // dist/mac, dist/mac-arm64, …
                if let a = app(in: (s as NSString).appendingPathComponent(arch)) { return a }
            }
        }
        return nil
    }

    private func bundleID(bundle: String?, buildSh: String, pkg: NSDictionary?, folder: String) -> String {
        if let b = bundle,
           let d = NSDictionary(contentsOfFile: (b as NSString).appendingPathComponent("Contents/Info.plist")),
           let id = d["CFBundleIdentifier"] as? String { return id }
        if let text = try? String(contentsOfFile: buildSh, encoding: .utf8),
           let id = firstMatch(in: text, pattern: "CFBundleIdentifier</key><string>([^<]+)</string>") { return id }
        if let name = pkg?["name"] as? String { return "local.\(name)" }
        return "local.\(folder.lowercased())"
    }

    private func displayName(bundle: String?, pkg: NSDictionary?, folder: String) -> String {
        if let b = bundle,
           let d = NSDictionary(contentsOfFile: (b as NSString).appendingPathComponent("Contents/Info.plist")),
           let n = (d["CFBundleDisplayName"] ?? d["CFBundleName"]) as? String { return n }
        return folder
    }

    private func configApps() -> [AppInfo] {
        guard let data = FileManager.default.contents(atPath: NexusHome.config),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let dir = o["dir"] as? String else { return nil }
            let name = o["name"] as? String ?? (dir as NSString).lastPathComponent
            let kind = o["kind"] as? String ?? "swift"
            let id = o["id"] as? String ?? "local.\(name.lowercased())"
            let bundle = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.first { $0.hasSuffix(".app") }
                .map { (dir as NSString).appendingPathComponent($0) }
            return AppInfo(id: id, name: name, dir: dir, kind: kind, bundlePath: bundle)
        }
    }

    private func readBeats() -> [String: Beat] {
        var out: [String: Beat] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: NexusHome.heartbeats)) ?? []
        for f in files where f.hasSuffix(".json") {
            let path = (NexusHome.heartbeats as NSString).appendingPathComponent(f)
            if let b = Beat.read(path) {
                out[(f as NSString).deletingPathExtension] = b
            }
        }
        return out
    }

    /// A Swift app needs rebuilding when any source file is newer than its built binary.
    private func computeNeedsBuild(_ app: AppInfo) -> Bool {
        guard app.kind == "swift", let bundle = app.bundlePath else { return false }
        let fm = FileManager.default
        let macOS = (bundle as NSString).appendingPathComponent("Contents/MacOS")
        let bins = (try? fm.contentsOfDirectory(atPath: macOS)) ?? []
        guard let binMtime = bins.compactMap({ mtime((macOS as NSString).appendingPathComponent($0)) }).max() else { return false }
        return newestSource(in: app.dir) > binMtime
    }

    private func newestSource(in dir: String) -> Date {
        let fm = FileManager.default
        var newest = Date.distantPast
        let base = URL(fileURLWithPath: dir)
        let en = fm.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
        while let url = en?.nextObject() as? URL {
            let p = url.path
            if p.contains(".app/") || p.contains("/node_modules/") || p.contains("/.git/")
                || p.contains("/dist/") || p.contains("/build/") { en?.skipDescendants(); continue }
            guard ["swift", "html", "js", "css", "swift"].contains(url.pathExtension) else { continue }
            if let m = mtime(p), m > newest { newest = m }
        }
        return newest
    }

    private func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: Tiny parsing helpers

    private func parseJSON(_ path: String) -> NSDictionary? {
        guard let data = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return o as NSDictionary
    }

    private func jsonMentionsElectron(_ path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return text.contains("electron")
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

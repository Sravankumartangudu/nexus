// NexusBeacon — drop-in heartbeat for Nexus (the fleet monitor).
//
// To make any Swift app visible to Nexus with live health:
//   1. Copy this file into the app folder and add NexusBeacon.swift to build.sh's source list.
//   2. Call once at launch, e.g. in applicationDidFinishLaunching:
//          NexusBeacon.start(name: "Jarvis")
//      or, to report richer health, pass a closure returning (status, detail):
//          NexusBeacon.start(name: "Jarvis") { Voice.isListening ? ("ok", "listening") : ("warn", "mic off") }
//
// It writes ~/.nexus/heartbeats/<bundleid>.json every 30s and a final "offline" beat on quit.
// Nothing else in the app needs to change, and there is no dependency on Nexus being installed.

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
        }
    }

    static func beat() {
        let (s, d) = provider?() ?? ("ok", "")
        write(status: s, detail: d)
    }

    private static func write(status: String, detail: String) {
        let id = Bundle.main.bundleIdentifier ?? "local.\(appName.lowercased())"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".nexus/heartbeats")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = (dir as NSString).appendingPathComponent("\(id).json")
        let obj: [String: Any] = [
            "id": id, "name": appName, "version": version,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "status": status, "detail": detail,
            "ts": Int(Date().timeIntervalSince1970),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: file))
        }
    }
}

// Folder — Nexus as the menu-bar folder for the fleet.
//
// macOS won't let one app hold another's menu-bar item, so each app's NexusBeacon mirrors its own
// menu to ~/.nexus/menus/<bundleid>.json and runs the items Nexus asks for through
// ~/.nexus/inbox/<bundleid>/. Nexus shows that menu inside the app's submenu.
// With "Keep Agents in Nexus" on (~/.nexus/folder.json; each parent has its own file) the apps hide their own items, except the
// ones on the "shown" list. Whenever Nexus isn't running, every app shows its item again.

import AppKit

enum Folder {
    private static let home = URL(fileURLWithPath: NexusHome.root)
    private static let configURL = home.appendingPathComponent(Edition.folderFile)

    private static var config: [String: Any] {
        get {
            (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        set {
            if let data = try? JSONSerialization.data(withJSONObject: newValue, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: configURL, options: .atomic)
            }
            broadcast(["cmd": "folder"])
        }
    }

    /// "Keep Agents in Nexus": the apps hide their own menu-bar items.
    static var enabled: Bool {
        get { config["enabled"] as? Bool ?? false }
        set { var c = config; c["enabled"] = newValue; config = c }
    }

    /// Apps that keep their own item even while the folder is on.
    static func isShown(_ id: String) -> Bool { (config["shown"] as? [String] ?? []).contains(id) }
    static func setShown(_ id: String, _ on: Bool) {
        var c = config
        var s = Set(c["shown"] as? [String] ?? [])
        if on { s.insert(id) } else { s.remove(id) }
        c["shown"] = s.sorted()
        config = c
    }

    /// Whether the app's beacon can live in Nexus (it has set up an inbox).
    static func attached(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: inbox(id).path)
    }

    private static func inbox(_ id: String) -> URL { home.appendingPathComponent("inbox/\(id)") }

    static func send(_ id: String, _ cmd: [String: Any]) {
        guard attached(id), let data = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        let name = String(format: "%013.0f-%04d.json", Date().timeIntervalSince1970 * 1000, Int.random(in: 0..<10000))
        try? data.write(to: inbox(id).appendingPathComponent(name), options: .atomic)
    }

    static func broadcast(_ cmd: [String: Any]) {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("inbox").path)) ?? []
        for id in ids where !id.hasPrefix(".") { send(id, cmd) }
    }

    /// The app's mirrored menu, as last written by its beacon.
    static func menu(_ id: String) -> [[String: Any]]? {
        let url = home.appendingPathComponent("menus/\(id).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["items"] as? [[String: Any]]
    }

    /// Fills `menu` with the app's own items; picking one runs it in the app.
    static func fill(_ menu: NSMenu, _ items: [[String: Any]], app id: String, path: [Int] = [], target: AnyObject, action: Selector) {
        for e in items {
            if e["sep"] as? Bool == true { menu.addItem(.separator()); continue }
            let p = path + [e["i"] as? Int ?? 0]
            let title = e["t"] as? String ?? ""
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.state = e["s"] as? Bool == true ? .on : .off
            if let kids = e["k"] as? [[String: Any]] {
                let sub = NSMenu()
                fill(sub, kids, app: id, path: p, target: target, action: action)
                mi.submenu = sub
            } else if e["e"] as? Bool ?? true {
                mi.action = action
                mi.target = target
                mi.representedObject = ["id": id, "path": p, "title": title] as [String: Any]
            } else {
                mi.isEnabled = false
            }
            menu.addItem(mi)
        }
    }
}

/// Builds an app's submenu when it opens, so it shows the menu the app has just mirrored.
final class AppMenuDelegate: NSObject, NSMenuDelegate {
    let build: (NSMenu) -> Void
    init(_ build: @escaping (NSMenu) -> Void) { self.build = build }
    func menuNeedsUpdate(_ menu: NSMenu) { menu.removeAllItems(); build(menu) }
}

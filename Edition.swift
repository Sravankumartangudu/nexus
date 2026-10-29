// Edition — what makes this parent app Nexus rather than another parent built on the same core.
//
// The core (main, Fleet, Voice, Brain, Folder, dashboard, orb) is shared between parents; each
// parent keeps only this file of its own: its name, which teams of apps it watches, its menu-bar
// symbol, and the hooks where its own features plug in. Nexus watches personal apps — those on
// public GitHub and any not on git yet. Apps on the work GitHub (git.soma) belong to the work
// parent, so they're left out here.

import AppKit

enum Edition {
    /// Shown everywhere the app names itself, and the default wake word.
    static let name = "Nexus"
    static let bundleId = "com.stangudu.nexus"
    /// The "keep agents in the folder" settings file in ~/.nexus, read by each app's beacon.
    static let folderFile = "folder.json"
    /// Menu-bar symbol, tinted by the fleet's worst status.
    static let symbol = "point.3.connected.trianglepath.dotted"
    /// One line for the voice brain: whose apps these are and a few of them by name.
    static let fleetBlurb = "the user's personal apps — Water Buddy, Animi, Dharalu, T-Minus, and others"

    /// The voice orb's palette and look (orb.html `THEMES`): cyan for Nexus.
    static let orbTheme = "nexus"

    /// The teams this parent watches (see `Team`).
    static func watches(_ team: String) -> Bool { team != Team.work }

    /// Called once at launch, after the menu bar and fleet are up.
    static func setUp() {}

    /// Adds this edition's own items to the menu-bar menu, just above Settings….
    static func addMenuItems(to menu: NSMenu) {
        // 🎨 Style per App: the design each personal app wears (StylesWindow, Nexus only).
        let styles = NSMenuItem(title: "🎨 Style per App…", action: #selector(StylesWindow.show), keyEquivalent: "")
        styles.target = StylesWindow.shared
        menu.addItem(styles)
    }

    /// The Claude model for the voice brain, given the app's own setting.
    static func brainModel(_ own: String) -> String { own }

    /// Called with the `result` event of each finished voice-brain turn (cost, tokens, timing).
    static func brainTurnDone(_ result: [String: Any]) {}
}

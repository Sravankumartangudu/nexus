// StylesWindow — Nexus › 🎨 Style per App…: the design style each personal app wears, picked here or in the
// app's own Settings, the same in both (styles/FleetStyles.swift keeps ~/.nexus/styles.json between them).
// Nexus's own windows keep their look; it's the parent, so it only hosts the picks.

import AppKit
import WebKit

final class StylesWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = StylesWindow()

    private var window: NSWindow?
    private var web: WKWebView?
    private var loaded = false
    private var watching = false

    @objc func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            push()
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Style per App"
        w.titlebarAppearsTransparent = true
        // Matches the page's --bg0 in each look, like the dashboard.
        w.backgroundColor = NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 7/255, green: 10/255, blue: 18/255, alpha: 1)
                : NSColor(red: 236/255, green: 239/255, blue: 246/255, alpha: 1)
        }
        w.minSize = NSSize(width: 460, height: 360)
        w.center()
        w.isReleasedWhenClosed = false

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "nexus")
        let wv = WKWebView(frame: w.contentView!.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        if let html = Bundle.main.url(forResource: "styles", withExtension: "html") {
            wv.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        w.contentView?.addSubview(wv)
        window = w; web = wv
        if !watching { watching = true; FleetStyles.watch { [weak self] in self?.push() } }   // picks made in the apps
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        push()
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String], body["action"] == "style",
              let id = body["id"], let style = body["style"] else { return }
        FleetStyles.set(style, for: id)
        push()
    }

    private func push() {
        guard loaded, let web, window?.isVisible == true,
              let data = try? JSONSerialization.data(withJSONObject: ["apps": FleetStyles.apps()]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("render(\(json))", completionHandler: nil)
    }
}

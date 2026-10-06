// Draws the Nexus app icon and writes Icon/AppIcon.icns.
// Run: swift Icon/make_icon.swift   (from the project root)
//
// Motif: a bright central hub with spokes out to satellite nodes — the head of the fleet.

import AppKit

let S: CGFloat = 1024

func drawIcon(in ctx: CGContext) {
    let cs = CGColorSpaceCreateDeviceRGB()
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
    func grad(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
        CGGradient(colorsSpace: cs, colors: stops.map { color($0.0, $0.1) } as CFArray,
                   locations: stops.map { $0.2 })!
    }

    // Tile: macOS-style rounded square.
    let inset: CGFloat = 100
    let tile = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.45))
    ctx.addPath(tilePath); ctx.setFillColor(color(0x0b1020)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    ctx.drawLinearGradient(grad([(0x16213f, 1, 0), (0x090d18, 1, 1)]),
                           start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    let center = CGPoint(x: S / 2, y: S / 2)
    let R: CGFloat = 265
    // Six satellite nodes evenly around the hub.
    var sats: [CGPoint] = []
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3 - .pi / 2
        sats.append(CGPoint(x: center.x + R * cos(a), y: center.y + R * sin(a)))
    }

    // Spokes.
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    for p in sats {
        ctx.move(to: center); ctx.addLine(to: p)
    }
    ctx.setStrokeColor(color(0x4a9eff, 0.55)); ctx.strokePath()

    // Faint ring connecting the satellites.
    ctx.setLineWidth(8)
    for i in 0..<6 {
        ctx.move(to: sats[i]); ctx.addLine(to: sats[(i + 1) % 6])
    }
    ctx.setStrokeColor(color(0x3a6fd0, 0.28)); ctx.strokePath()

    // Satellite node glows + dots.
    for p in sats {
        ctx.drawRadialGradient(grad([(0x5ec6ff, 0.5, 0), (0x5ec6ff, 0, 1)]),
                               startCenter: p, startRadius: 0, endCenter: p, endRadius: 95, options: [])
        ctx.addPath(CGPath(ellipseIn: CGRect(x: p.x - 34, y: p.y - 34, width: 68, height: 68), transform: nil))
        ctx.setFillColor(color(0xbfe3ff)); ctx.fillPath()
    }

    // Central hub: big glowing node.
    ctx.drawRadialGradient(grad([(0x4a9eff, 0.9, 0), (0x4a9eff, 0, 1)]),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: 240, options: [])
    let hub = CGPath(ellipseIn: CGRect(x: center.x - 92, y: center.y - 92, width: 184, height: 184), transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 50, color: color(0x6cc0ff, 0.9))
    ctx.addPath(hub); ctx.setFillColor(color(0xffffff)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(hub); ctx.clip()
    ctx.drawLinearGradient(grad([(0xeaf5ff, 1, 0), (0x8cc6ff, 1, 1)]),
                           start: CGPoint(x: center.x, y: center.y + 92), end: CGPoint(x: center.x, y: center.y - 92), options: [])
    ctx.resetClip()

    ctx.restoreGState()   // end tile clip
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = g.cgContext
    ctx.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)
    ctx.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    drawIcon(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: root.appendingPathComponent("preview.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "Wrote \(root.path)/AppIcon.icns" : "iconutil failed")

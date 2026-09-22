import AppKit
import SwiftUI

/// Developer tools for producing images of the app:
///   Orbit --snapshot out.png [--dark]   the panel with live data
///   Orbit --faces out.png               every expression, glossy and menu-bar style
///   Orbit --app-icon Orbit.iconset      the app icon at every size iconutil expects
enum Snapshot {
    @MainActor
    static func runIfRequested(store: UsageStore, animator: FaceAnimator) {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let path = value(after: "--faces") { renderFaces(to: path) }
        if let dir = value(after: "--app-icon") { renderAppIcon(into: dir) }
        guard let path = value(after: "--snapshot") else { return }
        let dark = args.contains("--dark")
        Task { @MainActor in
            while store.lastRefresh == nil { try? await Task.sleep(for: .milliseconds(200)) }
            if args.contains("--connect") { store.editingKeyFor = .claude }
            if args.contains("--confirm-remove") { store.editingKeyFor = .claude; CredentialRow.previewConfirming = true }
            // Sample numbers, to check the layout of the API spend row.
            if args.contains("--sample-spend") { store.claude.spend = Spend(today: 1.84, month: 42.17, currency: "USD") }
            renderPanel(store: store, animator: animator, dark: dark, to: path)
            exit(0)
        }
    }

    /// Renders through AppKit rather than ImageRenderer so native controls draw for real.
    @MainActor
    private static func renderPanel(store: UsageStore, animator: FaceAnimator, dark: Bool, to path: String) {
        let hosting = NSHostingView(rootView: PanelView().environment(store).environment(animator))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        hosting.frame = background.bounds
        background.addSubview(hosting)
        window.contentView = background
        background.layoutSubtreeIfNeeded()
        // Give SwiftUI a moment to settle its first layout pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = background.bitmapImageRepForCachingDisplay(in: background.bounds) else { return }
        background.cacheDisplay(in: background.bounds, to: rep)
        write(rep, to: path)
    }

    @MainActor
    private static func renderAppIcon(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let suffix = scale == 2 ? "@2x" : ""
                write(appIcon(pixels: px), to: "\(dir)/icon_\(base)x\(base)\(suffix).png")
            }
        }
        exit(0)
    }

    /// The glossy orb on a dark, softly lit squircle, following the macOS icon grid.
    private static func appIcon(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let cg = NSGraphicsContext.current!.cgContext
        let k = CGFloat(pixels) / 1024
        cg.scaleBy(x: k, y: k)

        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        cg.addPath(shape)
        cg.setFillColor(NSColor.black.cgColor)
        cg.fillPath()
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bg = CGGradient(colorsSpace: space, colors: [
            NSColor(srgbRed: 0.20, green: 0.21, blue: 0.27, alpha: 1).cgColor,
            NSColor(srgbRed: 0.07, green: 0.07, blue: 0.10, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        // A faint glow behind the orb.
        let glow = CGGradient(colorsSpace: space, colors: [
            NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
        ] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                              endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])
        cg.restoreGState()

        let orb = OrbFace.image(size: 540)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        orb.draw(in: NSRect(x: 242, y: 250, width: 540, height: 540))
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Every expression at menu-bar size and larger, on light and dark strips.
    @MainActor
    private static func renderFaces(to path: String) {
        let faces: [(FaceExpression, OrbPalette, String)] = [
            (.neutral, .white, "neutral"), (.focused, .white, "focused"), (.doubtful, .white, "doubtful"),
            (.cross, .red, "cross"), (.happy, .white, "happy"), (.dizzy, .white, "dizzy"), (.neutral, .white, "blink"),
        ]
        let view = VStack(spacing: 0) {
            ForEach([Color(white: 0.93), Color(white: 0.14)], id: \.self) { bg in
                HStack(spacing: 18) {
                    ForEach(faces.indices, id: \.self) { i in
                        let (e, p, name) = faces[i]
                        let lid: CGFloat = name == "blink" ? 0.08 : 1
                        VStack(spacing: 6) {
                            Image(nsImage: OrbFace.image(size: 96, expression: e, palette: p, lid: lid))
                            HStack(spacing: 8) {
                                Image(nsImage: OrbFace.image(size: 36, expression: e, palette: p, lid: lid))
                                Image(nsImage: OrbFace.image(size: 18, expression: e, lid: lid, outline: true,
                                                             tint: p == .red ? .systemRed : nil))
                                    .foregroundStyle(bg == Color(white: 0.14) ? Color.white : Color.black)
                                    .padding(3)
                                    .background(bg == Color(white: 0.14) ? Color(white: 0.22) : Color.white.opacity(0.7))
                            }
                            Text(name).font(.caption).foregroundStyle(.gray)
                        }
                    }
                }
                .padding(16)
                .background(bg)
            }
        }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            write(rep, to: path)
        }
        exit(0)
    }

    private static func write(_ rep: NSBitmapImageRep, to path: String) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

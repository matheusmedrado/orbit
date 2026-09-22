import AppKit
import Observation
import SwiftUI

// A native port of SmoothUI's AI Orb Face (MIT, © SmoothUI / Eduardo Calvo):
// https://smoothui.dev/docs/components/ai-orb-face
// A glossy orb with two capsule eyes. Status is carried by the expression.

/// One eye: multipliers on the resting capsule, plus tilt and vertical offset.
struct EyeShape {
    var h: CGFloat
    var w: CGFloat = 1
    var rotate: CGFloat = 0
    var dy: CGFloat = 0
}

enum FaceExpression {
    case neutral, focused, doubtful, cross, happy, dizzy

    var eyes: (left: EyeShape, right: EyeShape) {
        switch self {
        case .neutral: (EyeShape(h: 1), EyeShape(h: 1))
        case .focused: (EyeShape(h: 0.72, w: 1.05, dy: 1), EyeShape(h: 0.72, w: 1.05, dy: 1))
        case .doubtful: (EyeShape(h: 1), EyeShape(h: 0.6, w: 1.08, rotate: -14, dy: 2))
        case .cross: (EyeShape(h: 0.9, rotate: 18), EyeShape(h: 0.9, rotate: -18))
        case .happy, .dizzy: (EyeShape(h: 1), EyeShape(h: 1)) // drawn as arcs / spirals
        }
    }
}

enum OrbPalette {
    case white, red

    var body: NSColor {
        self == .white ? NSColor(srgbRed: 0.80, green: 0.82, blue: 0.87, alpha: 1)
                       : NSColor(srgbRed: 0.975, green: 0.253, blue: 0.266, alpha: 1)
    }
    var edge: NSColor {
        self == .white ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                       : NSColor(srgbRed: 1, green: 0.92, blue: 0.909, alpha: 1)
    }
    static let feature = NSColor(srgbRed: 0.111, green: 0.116, blue: 0.178, alpha: 1)
}

enum OrbFace {
    // Geometry in a 100×100 box, same numbers as the original component.
    private static let center: CGFloat = 50
    private static let eyeOffset: CGFloat = 16
    // Eyes are ~20% larger than the original so they read at menu-bar size.
    private static let eyeY: CGFloat = 40
    private static let eyeWidth: CGFloat = 13.5
    private static let eyeHeight: CGFloat = 32
    private static let eyeRadius: CGFloat = 6.75

    /// - Parameters:
    ///   - lid: 1 = open, ~0.08 = mid-blink.
    ///   - gaze: pupil offset in box units (the original allows up to ±5.5).
    ///   - outline: draw a single-color ring + eyes instead of the glossy orb. With no
    ///     tint it's a template image, so macOS colors it to match the menu bar.
    static func image(
        size: CGFloat,
        expression: FaceExpression = .neutral,
        palette: OrbPalette = .white,
        lid: CGFloat = 1,
        gaze: CGPoint = .zero,
        outline: Bool = false,
        tint: NSColor? = nil
    ) -> NSImage {
        let ink = outline ? (tint ?? .black).cgColor : OrbPalette.feature.cgColor
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let k = rect.width / 100
            cg.scaleBy(x: k, y: k)
            if outline {
                drawRing(cg, ink: ink, pointsPerUnit: k)
            } else {
                drawBody(cg, palette: palette, pointsPerUnit: k)
            }
            cg.setFillColor(ink)
            cg.setStrokeColor(ink)
            switch expression {
            case .dizzy:
                for side: CGFloat in [-1, 1] { drawSpiral(cg, side: side) }
            case .happy:
                for side: CGFloat in [-1, 1] { drawHappyArc(cg, side: side) }
            default:
                let eyes = expression.eyes
                drawEye(cg, side: -1, shape: eyes.left, lid: lid, gaze: gaze)
                drawEye(cg, side: 1, shape: eyes.right, lid: lid, gaze: gaze)
            }
            return true
        }
        image.isTemplate = outline && tint == nil
        image.accessibilityDescription = "Orbit"
        return image
    }

    private static func drawBody(_ cg: CGContext, palette: OrbPalette, pointsPerUnit k: CGFloat) {
        let sphere = CGRect(x: 2, y: 2, width: 96, height: 96)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        cg.saveGState()
        cg.addEllipse(in: sphere)
        cg.clip()
        // Highlight up-left fading into the body color, like the original's
        // `radial-gradient(circle at 34% 30%, edge, body 72%)`.
        let light = CGGradient(colorsSpace: space, colors: [palette.edge.cgColor, palette.body.cgColor] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(light, startCenter: CGPoint(x: 34, y: 30), startRadius: 0,
                              endCenter: CGPoint(x: 34, y: 30), endRadius: 70, options: [.drawsAfterEndLocation])
        // Soft shading toward the rim gives it volume.
        let rim = CGGradient(colorsSpace: space, colors: [
            palette.body.withAlphaComponent(0).cgColor,
            palette.body.blended(withFraction: 0.35, of: .black)!.withAlphaComponent(0.55).cgColor,
        ] as CFArray, locations: [0.6, 1])!
        cg.drawRadialGradient(rim, startCenter: CGPoint(x: 46, y: 44), startRadius: 0,
                              endCenter: CGPoint(x: 50, y: 50), endRadius: 50, options: [])
        cg.restoreGState()
        // Faint outline so a white orb doesn't dissolve into a light menu bar.
        // A hairline: ~0.75pt at any size.
        let hairline = 0.75 / k
        cg.addEllipse(in: sphere.insetBy(dx: hairline / 2, dy: hairline / 2))
        cg.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        cg.setLineWidth(hairline)
        cg.strokePath()
    }

    /// ~1.6pt ring, like SF Symbols' regular weight at menu-bar size.
    private static func drawRing(_ cg: CGContext, ink: CGColor, pointsPerUnit k: CGFloat) {
        let width = 1.6 / k
        cg.addEllipse(in: CGRect(x: 2, y: 2, width: 96, height: 96).insetBy(dx: width / 2, dy: width / 2))
        cg.setStrokeColor(ink)
        cg.setLineWidth(width)
        cg.strokePath()
    }

    private static func drawEye(_ cg: CGContext, side: CGFloat, shape: EyeShape, lid: CGFloat, gaze: CGPoint) {
        let width = eyeWidth * shape.w
        let height = max(eyeHeight * shape.h * lid, 0.5)
        let cx = center + side * eyeOffset + gaze.x
        let cy = eyeY + eyeHeight / 2 + shape.dy + gaze.y
        let radius = min(eyeRadius * shape.w, height / 2)
        cg.saveGState()
        cg.translateBy(x: cx, y: cy)
        cg.rotate(by: shape.rotate * .pi / 180)
        let path = CGPath(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)
        cg.addPath(path)
        cg.fillPath()
        cg.restoreGState()
    }

    /// Closed, upturned "^ ^" eyes.
    private static func drawHappyArc(_ cg: CGContext, side: CGFloat) {
        let cx = center + side * eyeOffset
        let cy = eyeY + eyeHeight / 2
        let half: CGFloat = 8
        cg.move(to: CGPoint(x: cx - half, y: cy + 4))
        cg.addQuadCurve(to: CGPoint(x: cx + half, y: cy + 4), control: CGPoint(x: cx, y: cy - 10))
        cg.setLineWidth(5.5)
        cg.setLineCap(.round)
        cg.strokePath()
    }

    /// The original's ~1.25-turn swirl: "M0 0 C-0.6 -4 5 -5 6 -0.6 C7 4.5 1 8 -4 6 C-9 4.5 -9.5 -2 -6 -6"
    private static func drawSpiral(_ cg: CGContext, side: CGFloat) {
        cg.saveGState()
        cg.translateBy(x: center + side * eyeOffset, y: eyeY + eyeHeight / 2)
        if side > 0 { cg.scaleBy(x: -1, y: 1) } // mirror the right eye
        cg.scaleBy(x: 1.5, y: 1.5)
        cg.move(to: .zero)
        cg.addCurve(to: CGPoint(x: 6, y: -0.6), control1: CGPoint(x: -0.6, y: -4), control2: CGPoint(x: 5, y: -5))
        cg.addCurve(to: CGPoint(x: -4, y: 6), control1: CGPoint(x: 7, y: 4.5), control2: CGPoint(x: 1, y: 8))
        cg.addCurve(to: CGPoint(x: -6, y: -6), control1: CGPoint(x: -9, y: 4.5), control2: CGPoint(x: -9.5, y: -2))
        cg.setLineWidth(3)
        cg.setLineCap(.round)
        cg.strokePath()
        cg.restoreGState()
    }
}

/// Drives the blink so the face feels alive. Kept separate from
/// UsageStore so a blink doesn't re-render the panel.
@MainActor
@Observable
final class FaceAnimator {
    private(set) var lid: CGFloat = 1
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                // Natural cadence: 3.2 to 5.8s apart, sometimes a double blink.
                try? await Task.sleep(for: .milliseconds(Int.random(in: 3200...5800)))
                await self?.blink(double: Double.random(in: 0...1) < 0.25)
            }
        }
    }

    private func blink(double: Bool) async {
        // Snap shut, ease open. An evenly timed blink reads as a machine.
        lid = 0.08
        try? await Task.sleep(for: .milliseconds(80))
        lid = 1
        if double {
            try? await Task.sleep(for: .milliseconds(90))
            lid = 0.08
            try? await Task.sleep(for: .milliseconds(80))
            lid = 1
        }
    }
}

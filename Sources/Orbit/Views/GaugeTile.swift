import SwiftUI

/// Ring gauge for one limit window: percent used, when it resets, and a warning
/// only if the current pace would hit the limit before then.
struct GaugeTile: View {
    let window: LimitWindow
    let now: Date

    private let diameter: CGFloat = 50
    private let lineWidth: CGFloat = 6

    var body: some View {
        HStack(spacing: 10) {
            ring
            VStack(alignment: .leading, spacing: 3) {
                Text(window.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(resetText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let warning {
                    Text(warning.text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(warning.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText)
    }

    private var ring: some View {
        let u = min(max(window.utilization, 0), 1)
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(u, 0.004))
                .stroke(usageColor(u).gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(Fmt.percent(u))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: diameter, height: diameter)
        .animation(.smooth, value: window.utilization)
    }

    private var resetText: String {
        guard let remaining = window.remaining(at: now) else { return "Not started" }
        return "\(Fmt.duration(remaining)) left"
    }

    private var helpText: String {
        var text = "\(window.label): \(Fmt.percent(window.utilization)) used"
        if let reset = window.resetsAt {
            text += " · resets \(reset.formatted(date: .abbreviated, time: .shortened))"
        }
        return text
    }

    /// Only shown when it matters: the limit is hit, or will be before the reset.
    private var warning: (text: String, color: Color)? {
        let u = window.utilization
        if u >= 1 { return ("Limit reached", .red) }
        guard u > 0.01, let duration = window.duration, let remaining = window.remaining(at: now) else { return nil }
        let elapsed = duration - remaining
        // Too early in the window to extrapolate meaningfully.
        guard elapsed > duration * 0.15 else { return nil }
        let secondsToFull = (1 - u) / (u / elapsed)
        guard secondsToFull < remaining else { return nil }
        return ("Limit in ~\(Fmt.duration(secondsToFull))", u >= 0.8 ? .red : .orange)
    }
}

struct Sparkline: View {
    let values: [Int]
    let tint: Color

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(values.indices, id: \.self) { i in
                    let v = values[i]
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(v == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(tint.opacity(0.75)))
                        .frame(height: v == 0 ? 1.5 : max(3, CGFloat(v) / CGFloat(peak) * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .help("Tokens per hour, last 24 hours")
    }
}

import SwiftUI

/// At a glance: limits and when they reset. Everything else lives behind the chevron.
struct ProviderCard: View {
    let snapshot: ProviderSnapshot
    let now: Date

    @State private var expanded = false
    @Environment(UsageStore.self) private var store

    private var accent: Color { snapshot.id.accent }
    private var editing: Bool { store.editingKeyFor == snapshot.id }
    /// Show the accounts section when something needs attention.
    private var needsAttention: Bool {
        snapshot.credentials.isEmpty || snapshot.hasRejectedCredential
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow

            if let message = snapshot.health.message {
                Banner(message: message, color: snapshot.health.color)
            }

            if !snapshot.windows.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(snapshot.windows) { GaugeTile(window: $0, now: now) }
                }
            } else if snapshot.health == .unknown {
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }

            if let spend = snapshot.spend {
                SpendRow(spend: spend)
            }

            if expanded || needsAttention || editing {
                AccountsSection(snapshot: snapshot, limitsSource: limitsSource)
            }

            summaryRow

            if expanded {
                DetailsView(snapshot: snapshot, accent: accent)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.smooth(duration: 0.25), value: expanded)
        .animation(.smooth(duration: 0.25), value: editing)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            ProviderMark(id: snapshot.id)
            Text(snapshot.id.displayName)
                .font(.system(size: 14, weight: .semibold))
            if let plan = snapshot.plan {
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if snapshot.local.isActive(at: now) {
                ActivityDot()
            } else if snapshot.health != .ok {
                Circle().fill(snapshot.health.color).frame(width: 7, height: 7)
                    .help(snapshot.health.title)
            }
        }
    }

    private var summaryRow: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 10) {
                Text("\(Fmt.compact(snapshot.local.today.total)) tokens today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Sparkline(values: snapshot.local.hourly, tint: accent)
                    .frame(width: 64, height: 16)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide details" : "Show details")
    }

    private var limitsSource: String {
        guard let updated = snapshot.limitsUpdated else { return "" }
        return (snapshot.limitsLive ? "Live · " : "From logs · ") + Fmt.ago(updated, now: now)
    }
}

/// The expanded section: secondary stats, breakdowns and notes.
private struct DetailsView: View {
    let snapshot: ProviderSnapshot
    let accent: Color

    var body: some View {
        let s = snapshot.local
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Stat(title: "Last 5 hours", value: Fmt.compact(s.last5h.total))
                    Stat(title: "Last 7 days", value: Fmt.compact(s.week.total))
                }
                GridRow {
                    Stat(title: "Burn rate", value: s.burnPerMinute > 0 ? "\(Fmt.compact(Int(s.burnPerMinute)))/min" : "idle")
                    Stat(title: "From cache", value: s.week.cacheHitRate.map(Fmt.percent) ?? "n/a")
                }
            }
            BarList(title: "Models", items: Array(s.byModel.prefix(3)), accent: accent)
            BarList(title: "Projects", items: Array(s.byProject.prefix(3)), accent: accent)
            ForEach(snapshot.notes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Pieces

extension ProviderID {
    var accent: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.36, green: 0.42, blue: 1.0)
        }
    }

    /// Bundled logo (Resources/<id>-logo.png), falling back to the source tree when
    /// running the bare binary during development.
    var logo: NSImage? { self == .claude ? Self.claudeLogo : Self.codexLogo }
    private static let claudeLogo = loadLogo("claude")
    private static let codexLogo = loadLogo("codex")

    private static func loadLogo(_ id: String) -> NSImage? {
        let name = "\(id)-logo"
        if let url = Bundle.main.url(forResource: name, withExtension: "png") { return NSImage(contentsOf: url) }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name).png")
        return NSImage(contentsOf: dev)
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

extension ProviderHealth {
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .limited, .error: .red
        case .unknown: .secondary
        }
    }

    var title: String {
        switch self {
        case .ok: "Allowed"
        case .warning: "Heads up"
        case .limited: "Limited"
        case .error: "Error"
        case .unknown: "Checking"
        }
    }
}

func usageColor(_ u: Double) -> Color {
    switch u {
    case ..<0.7: .green
    case ..<0.9: .orange
    default: .red
    }
}

private struct ProviderMark: View {
    let id: ProviderID
    var body: some View {
        if let logo = id.logo {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: id.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(id.accent)
                .frame(width: 22, height: 22)
                .background(id.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private struct ActivityDot: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text("Working")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Activity in the last 2 minutes")
    }
}

private struct Banner: View {
    let message: String
    let color: Color
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .symbolRenderingMode(.multicolor)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}

private struct BarList: View {
    let title: String
    let items: [NamedCount]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("No activity yet").font(.caption).foregroundStyle(.tertiary)
            }
            let peak = max(items.first?.tokens ?? 1, 1)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Fmt.compact(item.tokens)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        Capsule().fill(.quaternary)
                            .overlay(alignment: .leading) {
                                Capsule().fill(accent.opacity(0.8))
                                    .frame(width: max(3, geo.size.width * CGFloat(item.tokens) / CGFloat(peak)))
                            }
                    }
                    .frame(height: 3)
                }
            }
        }
    }
}

/// API spend from an Admin key.
private struct SpendRow: View {
    let spend: Spend

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            amount(spend.today, "today")
            amount(spend.month, "this month")
            Spacer()
            Text("API")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(.quaternary, in: Capsule())
        }
        .help("API spend, in UTC days")
    }

    private func amount(_ value: Double, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(spend.format(value))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The logins and keys a card uses, with a way to add or remove Orbit-managed keys.
private struct AccountsSection: View {
    let snapshot: ProviderSnapshot
    let limitsSource: String
    @Environment(UsageStore.self) private var store

    private var editing: Bool { store.editingKeyFor == snapshot.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(snapshot.credentials) { credential in
                CredentialRow(credential: credential, source: credential.keychainService == nil ? limitsSource : "")
            }
            if editing {
                KeyEditor(provider: snapshot.id)
            } else {
                Button(snapshot.credentials.isEmpty ? "Connect…" : "Add a key…") { store.editingKeyFor = snapshot.id }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

private struct CredentialRow: View {
    let credential: CredentialInfo
    let source: String
    @Environment(UsageStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(stateColor).frame(width: 6, height: 6)
            Text(credential.source)
            if let hint = credential.hint {
                Text(hint).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !source.isEmpty {
                Text(source).foregroundStyle(.tertiary)
            }
            if let service = credential.keychainService {
                Button("Remove") { Task { await store.removeKey(service) } }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(stateText)
    }

    private var stateColor: Color {
        switch credential.state {
        case .valid: .green
        case .rejected, .missing: .red
        case .unchecked: .secondary
        }
    }

    private var stateText: String {
        switch credential.state {
        case .valid: "Working"
        case .rejected: "Rejected"
        case .missing: "Not found"
        case .unchecked: "Not checked yet"
        }
    }
}

private struct KeyEditor: View {
    let provider: ProviderID
    @Environment(UsageStore.self) private var store
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var placeholder: String {
        provider == .claude ? "Paste a token or Admin key" : "Paste an Admin key"
    }

    private var hint: String {
        provider == .claude
            ? "A token from claude setup-token (sk-ant-oat…), or an Admin key (sk-ant-admin…) for API spend. Saved to your Keychain only."
            : "sk-admin… from OpenAI Platform > Settings > Admin keys. Saved to your Keychain only."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SecureField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .focused($focused)
                    .onSubmit(save)
                Button("Save", action: save)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.count < 20)
                Button("Cancel") { store.editingKeyFor = nil }
                    .controlSize(.small)
            }
            Text(error ?? hint)
                .font(.caption)
                .foregroundStyle(error == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { focused = true }
    }

    private func save() {
        guard trimmed.count >= 20 else { return }
        Task {
            error = await store.saveKey(trimmed)
            if error == nil { draft = "" }
        }
    }
}

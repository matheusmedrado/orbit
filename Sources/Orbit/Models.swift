import Foundation

struct ProviderFacts: Equatable {
    var displayName: String
    /// Settings label for a pasted key. Nil means this provider has no key editor.
    var pastedKeyTitle: String?
    var readsLocalLogs: Bool
}

enum ProviderID: String, CaseIterable, Identifiable {
    case claude, codex, grok
    var id: String { rawValue }

    var facts: ProviderFacts {
        switch self {
        case .claude:
            ProviderFacts(displayName: "Claude", pastedKeyTitle: "Connect Claude…", readsLocalLogs: true)
        case .codex:
            ProviderFacts(displayName: "Codex", pastedKeyTitle: "Connect OpenAI…", readsLocalLogs: true)
        case .grok:
            ProviderFacts(displayName: "Grok", pastedKeyTitle: nil, readsLocalLogs: false)
        }
    }

    var displayName: String { facts.displayName }
}

/// Included and spent amounts in major currency units. Remaining and the spent fraction come from these two.
struct PlanAllowance: Equatable {
    let included: Decimal
    let spent: Decimal
    let currencyCode: String

    init(included: Decimal, spent: Decimal, currencyCode: String) {
        self.included = max(included, 0)
        self.spent = max(spent, 0)
        self.currencyCode = currencyCode
    }

    var remaining: Decimal { max(included - spent, 0) }

    var fractionSpent: Double {
        guard included > 0 else { return spent > 0 ? 1 : 0 }
        let ratio = NSDecimalNumber(decimal: spent / included).doubleValue
        if ratio.isNaN { return 0 }
        return min(max(ratio, 0), 1)
    }

    /// "$15 left of $20"
    var summary: String { "\(format(remaining)) left of \(format(included))" }

    private func format(_ amount: Decimal) -> String {
        var original = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &original, 0, .plain)
        let places = rounded == amount ? 0 : 2
        return amount.formatted(
            .currency(code: currencyCode)
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(places)))
    }
}

enum IncludedPeriod: Equatable {
    case weekly
    case monthly

    var label: String { self == .weekly ? "Weekly" : "Monthly" }

    /// Pace window. A month has no fixed length, so the gauge only counts down to `resetsAt`.
    var duration: TimeInterval? { self == .weekly ? 7 * 86400 : nil }
}

/// One rate-limit window (e.g. the 5-hour session or the weekly cap), or one included-usage pool.
struct LimitWindow: Identifiable, Equatable {
    static let includedUsageID = "included"

    let id: String
    let label: String
    private let measuredUtilization: Double
    let resetsAt: Date?
    /// Total window length, used for pace/forecast.
    let duration: TimeInterval?
    let allowance: PlanAllowance?

    /// Rate-limit fraction, or the allowance's spent fraction when this is an included pool.
    var utilization: Double { allowance?.fractionSpent ?? measuredUtilization }

    init(id: String, label: String, utilization: Double, resetsAt: Date?, duration: TimeInterval?) {
        self.init(id: id, label: label, measuredUtilization: utilization, resetsAt: resetsAt, duration: duration, allowance: nil)
    }

    /// The only constructor that sets `allowance`. A `resetsAt` in the past does not change the fraction.
    static func includedUsage(
        period: IncludedPeriod,
        included: Decimal,
        spent: Decimal,
        currencyCode: String,
        resetsAt: Date
    ) -> LimitWindow {
        let allowance = PlanAllowance(included: included, spent: spent, currencyCode: currencyCode)
        return LimitWindow(
            id: includedUsageID,
            label: period.label,
            measuredUtilization: allowance.fractionSpent,
            resetsAt: resetsAt,
            duration: period.duration,
            allowance: allowance)
    }

    func remaining(at now: Date) -> TimeInterval? { resetsAt.map { max(0, $0.timeIntervalSince(now)) } }

    func elapsedFraction(at now: Date) -> Double? {
        guard let duration, duration > 0, let remaining = remaining(at: now) else { return nil }
        return min(max(1 - remaining / duration, 0), 1)
    }

    private init(id: String, label: String, measuredUtilization: Double, resetsAt: Date?, duration: TimeInterval?, allowance: PlanAllowance?) {
        self.id = id
        self.label = label
        self.measuredUtilization = measuredUtilization
        self.resetsAt = resetsAt
        self.duration = duration
        self.allowance = allowance
    }
}

struct TokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    /// Share of prompt tokens served from cache.
    var cacheHitRate: Double? {
        let prompt = input + cacheRead + cacheWrite
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }

    mutating func add(_ o: TokenCounts) {
        input += o.input; output += o.output; cacheRead += o.cacheRead; cacheWrite += o.cacheWrite
    }
}

struct UsageEvent {
    let date: Date
    let model: String
    let project: String
    let tokens: TokenCounts
}

struct NamedCount: Identifiable, Equatable {
    let name: String
    let tokens: Int
    var id: String { name }
}

/// Aggregates computed from local agent logs.
struct LocalStats: Equatable {
    var today = TokenCounts()
    var last5h = TokenCounts()
    var week = TokenCounts()
    var messagesToday = 0
    var byModel: [NamedCount] = []
    var byProject: [NamedCount] = []
    /// 24 hourly buckets, oldest first; last bucket is the current hour.
    var hourly: [Int] = Array(repeating: 0, count: 24)
    /// Tokens per minute over the last 15 minutes.
    var burnPerMinute: Double = 0
    var lastActivity: Date?

    func isActive(at now: Date) -> Bool {
        lastActivity.map { now.timeIntervalSince($0) < 120 } ?? false
    }

    static func build(from events: [UsageEvent], now: Date = Date()) -> LocalStats {
        var s = LocalStats()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let burnStart = now.addingTimeInterval(-15 * 60)
        var models: [String: Int] = [:]
        var projects: [String: Int] = [:]
        var burn = 0

        for e in events {
            if s.lastActivity.map({ e.date > $0 }) ?? true { s.lastActivity = e.date }
            guard e.date >= weekAgo else { continue }
            s.week.add(e.tokens)
            models[e.model, default: 0] += e.tokens.total
            projects[e.project, default: 0] += e.tokens.total
            if e.date >= startOfDay { s.today.add(e.tokens); s.messagesToday += 1 }
            if e.date >= fiveHoursAgo { s.last5h.add(e.tokens) }
            if e.date >= burnStart { burn += e.tokens.total }
            let hoursAgo = Int(now.timeIntervalSince(e.date) / 3600)
            if hoursAgo < 24 { s.hourly[23 - max(0, hoursAgo)] += e.tokens.total }
        }
        s.burnPerMinute = Double(burn) / 15
        s.byModel = models.map { NamedCount(name: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
        s.byProject = projects.map { NamedCount(name: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
        return s
    }
}

enum ProviderHealth: Equatable {
    case unknown
    case ok
    case warning(String)
    case limited(String)
    case error(String)

    var message: String? {
        switch self {
        case .warning(let m), .limited(let m), .error(let m): m
        case .unknown, .ok: nil
        }
    }
}

enum CredentialState: Equatable { case valid, rejected, missing, unchecked }

struct CredentialInfo: Equatable, Identifiable {
    var source: String
    var hint: String? = nil
    var state: CredentialState
    /// The Keychain item Orbit manages for this credential, so it can be removed.
    var keychainService: String? = nil
    var id: String { source }
}

struct ProviderSnapshot: Equatable {
    let id: ProviderID
    /// Set for an extra Claude Code login (e.g. "claude-work" for `~/.claude-work`).
    var account: String? = nil
    var windows: [LimitWindow] = []
    var health: ProviderHealth = .unknown
    var plan: String?
    var notes: [String] = []
    var local = LocalStats()
    var credentials: [CredentialInfo] = []
    /// API spend, when an Admin key is set up.
    var spend: Spend?
    /// When `windows` were last fetched successfully.
    var limitsUpdated: Date?
    /// True when limits came from a live API call rather than from logs.
    var limitsLive = false

    /// Unique per card, since extra Claude accounts share the `.claude` id.
    var key: String { account.map { "\(id.rawValue):\($0)" } ?? id.rawValue }

    var peakUtilization: Double { windows.map(\.utilization).max() ?? 0 }

    /// Worth a card: something is connected, or there's local activity.
    var isInUse: Bool {
        credentials.contains { $0.state != .missing } || local.lastActivity != nil
    }

    /// A key or login that used to work is being rejected.
    var hasRejectedCredential: Bool { credentials.contains { $0.state == .rejected } }
}

enum IconSeverity { case normal, warning, critical }

enum FetchError: Error {
    case unauthorized
    case failed(String)
}

// MARK: - Formatting

enum Fmt {
    static func compact(_ n: Int) -> String {
        let d = Double(n)
        func f(_ v: Double, _ unit: String) -> String {
            v >= 100 ? "\(Int(v.rounded()))\(unit)" : String(format: "%.1f%@", v, unit)
        }
        switch abs(d) {
        case 1e9...: return f(d / 1e9, "B")
        case 1e6...: return f(d / 1e6, "M")
        case 1e3...: return f(d / 1e3, "K")
        default: return "\(n)"
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < 5 { return "just now" }
        if s < 60 { return "\(Int(s))s ago" }
        return "\(duration(s)) ago"
    }

    static func windowLabel(seconds: Double?) -> String {
        guard let s = seconds, s > 0 else { return "Limit" }
        switch s {
        case 18000: return "5-hour"
        case 604800: return "Weekly"
        default: return s >= 86400 ? "\(Int(s / 86400))-day" : "\(Int(s / 3600))-hour"
        }
    }

    /// "claude-haiku-4-5-20251001" -> "Haiku 4.5"
    static func model(_ raw: String) -> String {
        guard raw.hasPrefix("claude-") else { return raw }
        var parts = raw.dropFirst("claude-".count).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return raw }
        let version = parts.dropFirst().joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    static func project(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    static func mask(_ token: String) -> String {
        guard token.count > 20 else { return "••••" }
        return "\(token.prefix(12))…\(token.suffix(4))"
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? 0 }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
}

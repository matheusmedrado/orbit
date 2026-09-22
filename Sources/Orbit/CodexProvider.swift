import Foundation

enum CodexProvider {
    static func fetch(previous: ProviderSnapshot, logs: CodexLogScanner) async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: .codex)
        let scan = await logs.scan()
        snap.local = LocalStats.build(from: scan.events)
        snap.plan = scan.plan.map(\.capitalized)

        guard let auth = CodexAPI.readAuth() else {
            snap.credential = CredentialInfo(source: "Codex login", hint: nil, state: .missing, editable: false)
            applyLogLimits(scan, to: &snap)
            snap.health = snap.windows.isEmpty
                ? .error("Not signed in to Codex. Run `codex login` in a terminal.")
                : .warning("Not signed in to Codex. Showing limits from your last session.")
            return snap
        }
        snap.credential = CredentialInfo(source: "ChatGPT login", hint: auth.accountHint, state: .unchecked, editable: false)

        do {
            let live = try await CodexAPI.usage(auth)
            snap.windows = live.windows
            snap.plan = live.plan?.capitalized ?? snap.plan
            snap.notes = live.notes
            snap.health = live.limitReached ? .limited("You've hit your Codex limit. It lifts when the window resets.") : .ok
            snap.limitsUpdated = Date()
            snap.limitsLive = true
            snap.credential?.state = .valid
        } catch FetchError.unauthorized {
            // Codex refreshes its own login; we never touch the refresh token.
            snap.credential?.state = .rejected
            applyLogLimits(scan, to: &snap)
            snap.health = .warning("Codex login has expired. Run `codex` once to refresh it. Showing limits from logs.")
        } catch {
            if previous.limitsLive {
                snap.windows = previous.windows
                snap.limitsUpdated = previous.limitsUpdated
                snap.limitsLive = true
            } else {
                applyLogLimits(scan, to: &snap)
            }
            snap.credential?.state = previous.credential?.state ?? .unchecked
            snap.health = .warning("Couldn't reach ChatGPT. Showing last known limits.")
        }
        return snap
    }

    private static func applyLogLimits(_ scan: CodexLogScanner.Result, to snap: inout ProviderSnapshot) {
        guard let limits = scan.limits else { return }
        let now = Date()
        // A window that has reset since the log was written is back to zero.
        snap.windows = limits.windows.map { w in
            guard let reset = w.resetsAt, reset <= now else { return w }
            return LimitWindow(id: w.id, label: w.label, utilization: 0, resetsAt: nil, duration: w.duration)
        }
        snap.limitsUpdated = limits.date
        snap.limitsLive = false
    }
}

enum CodexAPI {
    struct Auth {
        let accessToken: String
        let accountID: String?
        var accountHint: String? { accountID.map { "acct …" + $0.suffix(4) } }
    }

    struct Usage {
        var windows: [LimitWindow]
        var plan: String?
        var limitReached: Bool
        var notes: [String]
    }

    static func readAuth() -> Auth? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = json.dict("tokens"),
              let access = tokens["access_token"] as? String, !access.isEmpty
        else { return nil }
        return Auth(accessToken: access, accountID: tokens["account_id"] as? String)
    }

    /// Read-only GET of the same usage data Codex's `/status` shows.
    static func usage(_ auth: Auth) async throws -> Usage {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 20)
        req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = auth.accountID { req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FetchError.failed("no response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
        guard http.statusCode == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FetchError.failed("HTTP \(http.statusCode)")
        }

        let rateLimit = json.dict("rate_limit") ?? [:]
        let windows = ["primary_window", "secondary_window"].compactMap { key -> LimitWindow? in
            guard let w = rateLimit.dict(key), let used = w.double("used_percent") else { return nil }
            let seconds = w.double("limit_window_seconds")
            return LimitWindow(
                id: key,
                label: Fmt.windowLabel(seconds: seconds),
                utilization: used / 100,
                resetsAt: w.double("reset_at").map { Date(timeIntervalSince1970: $0) },
                duration: seconds)
        }.sorted { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }

        var notes: [String] = []
        if let credits = json.dict("credits"), credits["has_credits"] as? Bool == true {
            notes.append(credits["unlimited"] as? Bool == true
                ? "Unlimited credits"
                : "Credits balance: \(credits["balance"] as? String ?? "?")")
        }
        return Usage(
            windows: windows,
            plan: json["plan_type"] as? String,
            limitReached: rateLimit["limit_reached"] as? Bool == true || rateLimit["allowed"] as? Bool == false,
            notes: notes)
    }
}

/// Parses Codex session rollouts in ~/.codex/sessions. Token counts are cumulative
/// per session, so each event contributes the delta from the previous one.
actor CodexLogScanner {
    struct Result {
        var events: [UsageEvent]
        var limits: (date: Date, windows: [LimitWindow])?
        var plan: String?
    }

    private struct Cumulative { var input = 0, cached = 0, output = 0 }
    private struct FileContext { var model = "unknown", project = "unknown", totals = Cumulative() }

    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    private var tail = JSONLTail()
    private var files: [String: FileContext] = [:]
    private var events: [UsageEvent] = []
    private var limits: (date: Date, windows: [LimitWindow])?
    private var plan: String?
    private let iso = ISODate()
    private static let needles = ["\"token_count\"", "\"turn_context\"", "\"session_meta\""].map { Data($0.utf8) }

    func scan() -> Result {
        let horizon = Date().addingTimeInterval(-logHorizon)
        for url in JSONLTail.recentFiles(under: root, modifiedSince: horizon) {
            var reset = false
            let lines = tail.newLines(at: url, reset: &reset)
            if reset { files[url.path] = nil }
            var ctx = files[url.path] ?? FileContext()
            for line in lines where Self.needles.contains(where: line.has) {
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let payload = obj.dict("payload") else { continue }
                switch obj["type"] as? String {
                case "session_meta":
                    ctx.project = Fmt.project(payload["cwd"] as? String)
                case "turn_context":
                    if let m = payload["model"] as? String { ctx.model = m }
                    if let cwd = payload["cwd"] as? String { ctx.project = Fmt.project(cwd) }
                case "event_msg" where payload["type"] as? String == "token_count":
                    guard let date = (obj["timestamp"] as? String).flatMap(iso.parse) else { continue }
                    record(payload, date: date, horizon: horizon, ctx: &ctx)
                default: break
                }
            }
            files[url.path] = ctx
        }
        events.removeAll { $0.date < horizon }
        return Result(events: events, limits: limits, plan: plan)
    }

    private func record(_ payload: [String: Any], date: Date, horizon: Date, ctx: inout FileContext) {
        if let info = payload.dict("info"), let total = info.dict("total_token_usage") {
            let now = Cumulative(input: total.int("input_tokens"), cached: total.int("cached_input_tokens"), output: total.int("output_tokens"))
            var delta = Cumulative(input: now.input - ctx.totals.input, cached: now.cached - ctx.totals.cached, output: now.output - ctx.totals.output)
            if delta.input < 0 || delta.output < 0, let last = info.dict("last_token_usage") {
                // Totals went backwards (history compacted); fall back to the per-turn numbers.
                delta = Cumulative(input: last.int("input_tokens"), cached: last.int("cached_input_tokens"), output: last.int("output_tokens"))
            }
            ctx.totals = now
            if date >= horizon, delta.input + delta.output > 0 {
                events.append(UsageEvent(
                    date: date, model: ctx.model, project: ctx.project,
                    tokens: TokenCounts(input: max(0, delta.input - delta.cached), output: delta.output, cacheRead: max(0, delta.cached))))
            }
        }

        if let rl = payload.dict("rate_limits"), limits.map({ date > $0.date }) ?? true {
            let windows = ["primary", "secondary"].compactMap { key -> LimitWindow? in
                guard let w = rl.dict(key), let used = w.double("used_percent") else { return nil }
                let seconds = w.double("window_minutes").map { $0 * 60 }
                return LimitWindow(
                    id: key, label: Fmt.windowLabel(seconds: seconds), utilization: used / 100,
                    resetsAt: w.double("resets_at").map { Date(timeIntervalSince1970: $0) }, duration: seconds)
            }
            if !windows.isEmpty { limits = (date, windows) }
            if let p = rl["plan_type"] as? String { plan = p }
        }
    }
}

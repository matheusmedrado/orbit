import Foundation

enum ClaudeProvider {
    /// Subscription limits come from a setup token or Claude Code's own login; API spend
    /// comes from an Admin key. Any combination can be present.
    static func fetch(previous: ProviderSnapshot, logs: ClaudeLogScanner, login: ClaudeCodeLogin.Reader) async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: .claude)
        snap.local = LocalStats.build(from: await logs.scan())
        var problems: [String] = []
        var offline = false
        var limitsHealth: ProviderHealth = .ok

        func previousState(_ source: String) -> CredentialState {
            previous.credentials.first { $0.source == source }?.state ?? .unchecked
        }

        // Subscription limits. A setup token wins over the Claude Code login.
        var subscription: (token: String, info: CredentialInfo)?
        if let token = Keychain.read(Keychain.claudeToken) {
            subscription = (token, CredentialInfo(source: "Claude token", hint: Fmt.mask(token), state: .unchecked, keychainService: Keychain.claudeToken))
        } else if let cc = await login.current() {
            snap.plan = cc.plan
            let info = CredentialInfo(source: "Claude Code login", hint: nil, state: .unchecked)
            if cc.isExpired {
                snap.credentials.append(CredentialInfo(source: info.source, state: .rejected))
                problems.append("Your Claude Code login has expired. Open Claude Code once to refresh it.")
            } else {
                subscription = (cc.accessToken, info)
            }
        }
        if let subscription {
            let token = subscription.token
            var info = subscription.info
            do {
                let probe = try await ClaudeLimitsAPI.probe(token: token)
                snap.windows = probe.windows
                snap.notes = probe.notes
                snap.limitsUpdated = Date()
                snap.limitsLive = true
                limitsHealth = probe.health
                info.state = .valid
            } catch FetchError.unauthorized {
                info.state = .rejected
                if info.keychainService == nil {
                    await login.invalidate()
                    problems.append("Claude Code's login was rejected. Sign in to Claude Code again.")
                } else {
                    problems.append("Your Claude token was rejected. It may have been revoked or expired.")
                }
            } catch {
                // Keep the last known numbers rather than blanking the UI on a flaky network.
                snap.windows = previous.windows
                snap.limitsUpdated = previous.limitsUpdated
                snap.notes = previous.notes
                info.state = previousState(info.source)
                offline = true
            }
            snap.credentials.insert(info, at: 0)
        }

        // API spend.
        if let key = Keychain.read(Keychain.anthropicAdminKey) {
            var info = CredentialInfo(source: "Admin key", hint: Fmt.mask(key), state: .unchecked, keychainService: Keychain.anthropicAdminKey)
            do {
                snap.spend = try await AnthropicCosts.fetch(adminKey: key)
                info.state = .valid
            } catch FetchError.unauthorized {
                info.state = .rejected
                problems.append("Your Anthropic Admin key was rejected.")
            } catch {
                snap.spend = previous.spend
                info.state = previousState(info.source)
                offline = true
            }
            snap.credentials.append(info)
        }

        snap.health = combinedHealth(
            problems: problems, offline: offline, limits: limitsHealth, connected: !snap.credentials.isEmpty,
            service: "Anthropic",
            notConnected: "Sign in to Claude Code, or add a Claude token or an Admin API key.")
        return snap
    }
}

/// Worst first: broken credentials, then hitting a limit, then being offline.
func combinedHealth(problems: [String], offline: Bool, limits: ProviderHealth, connected: Bool, service: String, notConnected: String) -> ProviderHealth {
    if !connected { return .error(notConnected) }
    if !problems.isEmpty { return .error(problems.joined(separator: " ")) }
    if case .limited = limits { return limits }
    if offline { return .warning("Couldn't reach \(service). Showing the last known numbers.") }
    return limits
}

/// Live limits come back as `anthropic-ratelimit-unified-*` headers on any Messages call,
/// so we send the smallest possible request (1 output token on Haiku).
enum ClaudeLimitsAPI {
    struct Probe {
        var windows: [LimitWindow]
        var health: ProviderHealth
        var notes: [String]
    }

    static let probeModel = "claude-haiku-4-5-20251001"
    private static let prefix = "anthropic-ratelimit-unified-"

    static func probe(token: String) async throws -> Probe {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": probeModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FetchError.failed("no response") }
        if http.statusCode == 401 { throw FetchError.unauthorized }

        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }

        let windows = parseWindows(headers)
        guard !windows.isEmpty else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = body?.dict("error")?["message"] as? String ?? "HTTP \(http.statusCode)"
            if http.statusCode == 403 { throw FetchError.unauthorized }
            throw FetchError.failed(message)
        }

        let health: ProviderHealth = switch headers[prefix + "status"] {
        case "rejected": .limited("You've hit a usage limit. It lifts when the window resets.")
        case "allowed_warning": .warning("You're getting close to a usage limit.")
        default: .ok
        }

        var notes: [String] = []
        switch (headers[prefix + "overage-status"], headers[prefix + "overage-disabled-reason"]) {
        case ("allowed"?, _), ("allowed_warning"?, _):
            notes.append("Extra usage is on, so you can keep going past your limits.")
        case (_, "org_level_disabled"?):
            notes.append("Extra usage is turned off for your organization.")
        case (_, let reason?):
            notes.append("Extra usage unavailable (\(reason.replacingOccurrences(of: "_", with: " "))).")
        default: break
        }
        return Probe(windows: windows, health: health, notes: notes)
    }

    /// Finds every `<prefix><key>-utilization` header, e.g. keys "5h", "7d", "7d_opus".
    static func parseWindows(_ headers: [String: String]) -> [LimitWindow] {
        let suffix = "-utilization"
        var windows: [LimitWindow] = []
        for (name, value) in headers where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let key = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            guard let utilization = Double(value) else { continue }
            let reset = headers[prefix + key + "-reset"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            let seconds = windowSeconds(key)
            var label = Fmt.windowLabel(seconds: seconds)
            if let scope = key.split(separator: "_", maxSplits: 1).dropFirst().first {
                label += " · " + scope.capitalized
            }
            windows.append(LimitWindow(id: key, label: label, utilization: utilization, resetsAt: reset, duration: seconds))
        }
        return windows.sorted { ($0.duration ?? .infinity, $0.id) < ($1.duration ?? .infinity, $1.id) }
    }

    /// "5h" -> 18000, "7d_opus" -> 604800
    private static func windowSeconds(_ key: String) -> Double? {
        let base = key.split(separator: "_").first.map(String.init) ?? key
        guard let unit = base.last, let n = Double(base.dropLast()) else { return nil }
        switch unit {
        case "h": return n * 3600
        case "d": return n * 86400
        case "m": return n * 60
        default: return nil
        }
    }
}

/// Parses Claude Code's session logs in ~/.claude/projects.
actor ClaudeLogScanner {
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var tail = JSONLTail()
    private var seen = Set<String>()
    private var events: [UsageEvent] = []
    private let iso = ISODate()
    private static let needle = Data("\"usage\"".utf8)

    func scan() -> [UsageEvent] {
        let horizon = Date().addingTimeInterval(-logHorizon)
        for url in JSONLTail.recentFiles(under: root, modifiedSince: horizon) {
            var reset = false
            for line in tail.newLines(at: url, reset: &reset) where line.has(Self.needle) {
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj.dict("message"),
                      let usage = message.dict("usage"),
                      let date = (obj["timestamp"] as? String).flatMap(iso.parse),
                      date >= horizon
                else { continue }
                let model = message["model"] as? String ?? "unknown"
                if model == "<synthetic>" { continue }

                // A single API response is written as several lines (one per content block).
                let messageID = message["id"] as? String ?? ""
                let requestID = obj["requestId"] as? String ?? ""
                let key = messageID.isEmpty && requestID.isEmpty ? (obj["uuid"] as? String ?? UUID().uuidString) : "\(messageID)|\(requestID)"
                guard seen.insert(key).inserted else { continue }

                events.append(UsageEvent(
                    date: date,
                    model: Fmt.model(model),
                    project: Fmt.project(obj["cwd"] as? String),
                    tokens: TokenCounts(
                        input: usage.int("input_tokens"),
                        output: usage.int("output_tokens"),
                        cacheRead: usage.int("cache_read_input_tokens"),
                        cacheWrite: usage.int("cache_creation_input_tokens"))))
            }
        }
        events.removeAll { $0.date < horizon }
        return events
    }
}

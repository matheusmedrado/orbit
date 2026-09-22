import Foundation

enum ClaudeProvider {
    static func fetch(previous: ProviderSnapshot, logs: ClaudeLogScanner) async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: .claude)
        snap.local = LocalStats.build(from: await logs.scan())

        guard let token = Keychain.readClaudeToken() else {
            snap.health = .error("No token found in Keychain. Add one below.")
            snap.credential = CredentialInfo(source: "Keychain", hint: nil, state: .missing, editable: true)
            return snap
        }
        snap.credential = CredentialInfo(source: "Keychain", hint: Fmt.mask(token), state: .unchecked, editable: true)

        do {
            let probe = try await ClaudeLimitsAPI.probe(token: token)
            snap.windows = probe.windows
            snap.health = probe.health
            snap.notes = probe.notes
            snap.limitsUpdated = Date()
            snap.limitsLive = true
            snap.credential?.state = .valid
        } catch FetchError.unauthorized {
            snap.health = .error("Token was rejected. It may have been revoked or expired.")
            snap.credential?.state = .rejected
        } catch {
            // Keep the last known numbers rather than blanking the UI on a flaky network.
            snap.windows = previous.windows
            snap.limitsUpdated = previous.limitsUpdated
            snap.notes = previous.notes
            snap.credential?.state = previous.credential?.state ?? .unchecked
            let reason = (error as? FetchError).flatMap { if case .failed(let m) = $0 { m } else { nil } } ?? error.localizedDescription
            snap.health = .warning("Couldn't reach Anthropic (\(reason)). Showing last known limits.")
        }
        return snap
    }
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

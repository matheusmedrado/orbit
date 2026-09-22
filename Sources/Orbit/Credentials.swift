import Foundation

/// What a pasted key is, judged by its prefix.
enum KeyKind: Equatable {
    case claudeToken, anthropicAdmin, anthropicStandard, openAIAdmin, openAIStandard, unknown

    init(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch true {
        case key.hasPrefix("sk-ant-oat"): self = .claudeToken
        case key.hasPrefix("sk-ant-admin"): self = .anthropicAdmin
        case key.hasPrefix("sk-ant-"): self = .anthropicStandard
        case key.hasPrefix("sk-admin-"): self = .openAIAdmin
        case key.hasPrefix("sk-"): self = .openAIStandard
        default: self = .unknown
        }
    }

    /// Why a key can't be used, if it can't.
    var problem: String? {
        switch self {
        case .anthropicStandard:
            "Regular API keys can't read usage. Create an Admin key in Claude Console > Settings > Admin keys."
        case .openAIStandard:
            "Regular API keys can't read usage. Create an Admin key in OpenAI Platform > Settings > Admin keys."
        case .unknown:
            "That doesn't look like a Claude token or an API key."
        default: nil
        }
    }

    var keychainService: String? {
        switch self {
        case .claudeToken: Keychain.claudeToken
        case .anthropicAdmin: Keychain.anthropicAdminKey
        case .openAIAdmin: Keychain.openAIAdminKey
        default: nil
        }
    }

    var label: String {
        switch self {
        case .claudeToken: "Claude Code OAuth token"
        case .anthropicAdmin: "Orbit Anthropic Admin key"
        case .openAIAdmin: "Orbit OpenAI Admin key"
        default: "Orbit key"
        }
    }
}

/// A Claude subscription login that Claude Code already has on this Mac. Orbit only reads it;
/// Claude Code keeps it fresh, so we never touch the refresh token.
struct ClaudeCodeLogin {
    let accessToken: String
    let expiresAt: Date?
    let plan: String?

    var isExpired: Bool { expiresAt.map { $0 < Date() } ?? false }

    /// Parses `{"claudeAiOauth": {"accessToken", "expiresAt" (ms), "subscriptionType"}}`.
    static func parse(_ data: Data) -> ClaudeCodeLogin? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json.dict("claudeAiOauth"),
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return ClaudeCodeLogin(
            accessToken: token,
            expiresAt: oauth.double("expiresAt").map { Date(timeIntervalSince1970: $0 / 1000) },
            plan: (oauth["subscriptionType"] as? String).map(\.capitalized))
    }

    /// Reading Claude Code's Keychain item asks the user for permission once, so the result is
    /// cached and only re-read when it expires or stops working.
    actor Reader {
        private var cached: ClaudeCodeLogin?
        private var lastAttempt: Date?

        func current(forceReload: Bool = false) -> ClaudeCodeLogin? {
            if !forceReload, let cached, !cached.isExpired { return cached }
            // Don't hammer the Keychain (or the user) when there's no login to find.
            if !forceReload, cached == nil, let last = lastAttempt, Date().timeIntervalSince(last) < 600 { return nil }
            lastAttempt = Date()
            cached = Self.load()
            return cached
        }

        func invalidate() { cached = nil; lastAttempt = nil }

        private static func load() -> ClaudeCodeLogin? {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: file), let login = parse(data) { return login }
            guard Keychain.exists(Keychain.claudeCodeLogin),
                  let raw = Keychain.read(Keychain.claudeCodeLogin, account: nil)
            else { return nil }
            return parse(Data(raw.utf8))
        }
    }
}

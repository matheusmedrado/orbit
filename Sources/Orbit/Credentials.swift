import CryptoKit
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
        /// Claude Code's config folder; nil for the default `~/.claude`.
        private let configDir: URL?
        private var cached: ClaudeCodeLogin?
        private var lastAttempt: Date?

        init(configDir: URL? = nil) { self.configDir = configDir }

        func current(forceReload: Bool = false) -> ClaudeCodeLogin? {
            if !forceReload, let cached, !cached.isExpired { return cached }
            // Don't hammer the Keychain (or the user) when there's no login to find.
            if !forceReload, cached == nil, let last = lastAttempt, Date().timeIntervalSince(last) < 600 { return nil }
            lastAttempt = Date()
            cached = load()
            return cached
        }

        func invalidate() { cached = nil; lastAttempt = nil }

        private func load() -> ClaudeCodeLogin? {
            let dir = configDir ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
            if let data = try? Data(contentsOf: dir.appendingPathComponent(".credentials.json")), let login = parse(data) { return login }
            let service = configDir.map { keychainService(configDir: $0.path) } ?? Keychain.claudeCodeLogin
            guard Keychain.exists(service), let raw = Keychain.read(service, account: nil) else { return nil }
            return parse(Data(raw.utf8))
        }
    }

    /// Another login kept in its own folder with `CLAUDE_CONFIG_DIR`,
    /// e.g. `alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'`.
    struct Account {
        /// The folder name without the dot, e.g. "claude-work".
        let name: String
        let dir: URL
    }

    /// `~/.claude-*` folders that hold a login. Only checks that the Keychain item exists,
    /// so finding them never prompts.
    static func extraAccounts() -> [Account] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names.filter { $0.hasPrefix(".claude-") }.sorted().compactMap { name in
            let dir = home.appendingPathComponent(name)
            let hasLogin = FileManager.default.fileExists(atPath: dir.appendingPathComponent(".credentials.json").path)
                || Keychain.exists(keychainService(configDir: dir.path))
            return hasLogin ? Account(name: String(name.dropFirst()), dir: dir) : nil
        }
    }

    /// With `CLAUDE_CONFIG_DIR` set, Claude Code suffixes its Keychain item with the first
    /// 8 hex digits of the folder path's SHA-256.
    static func keychainService(configDir path: String) -> String {
        let digest = SHA256.hash(data: Data(path.precomposedStringWithCanonicalMapping.utf8))
        return Keychain.claudeCodeLogin + "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }
}

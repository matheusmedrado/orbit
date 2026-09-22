import Foundation

/// Reads/writes secrets through `/usr/bin/security`. Items created by that tool keep it on
/// their access list, so going through it avoids an "Orbit wants to use your keychain"
/// prompt after every rebuild.
enum Keychain {
    /// A Claude Code token from `claude setup-token`.
    static let claudeToken = "claude-code-oauth-token"
    /// Anthropic Admin API key (`sk-ant-admin...`), for API spend.
    static let anthropicAdminKey = "orbit-anthropic-admin-key"
    /// OpenAI Admin key (`sk-admin-...`), for API spend.
    static let openAIAdminKey = "orbit-openai-admin-key"
    /// Where Claude Code keeps its own subscription login. Owned by Claude Code, read only.
    static let claudeCodeLogin = "Claude Code-credentials"

    static func read(_ service: String, account: String? = NSUserName()) -> String? {
        var args = ["find-generic-password", "-s", service, "-w"]
        if let account { args += ["-a", account] }
        let out = run(args)
        return out?.isEmpty == false ? out : nil
    }

    /// Checks for an item without reading its secret, so it never triggers an access prompt.
    static func exists(_ service: String) -> Bool {
        run(["find-generic-password", "-s", service]) != nil
    }

    @discardableResult
    static func save(_ value: String, service: String, label: String) -> Bool {
        run(["add-generic-password", "-U", "-a", NSUserName(), "-s", service, "-l", label, "-w", value]) != nil
    }

    @discardableResult
    static func delete(_ service: String) -> Bool {
        run(["delete-generic-password", "-a", NSUserName(), "-s", service]) != nil
    }

    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

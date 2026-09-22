import Foundation

/// Reads/writes the Claude token through `/usr/bin/security`. The Keychain item was
/// created by that tool, so it's already on the item's access list. Going through it
/// avoids an "Orbit wants to use your keychain" prompt after every rebuild.
enum Keychain {
    static let claudeService = "claude-code-oauth-token"

    static func readClaudeToken() -> String? {
        let out = run(["find-generic-password", "-a", NSUserName(), "-s", claudeService, "-w"])
        return out?.isEmpty == false ? out : nil
    }

    @discardableResult
    static func saveClaudeToken(_ token: String) -> Bool {
        run(["add-generic-password", "-U", "-a", NSUserName(), "-s", claudeService,
             "-l", "Claude Code OAuth token", "-w", token]) != nil
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

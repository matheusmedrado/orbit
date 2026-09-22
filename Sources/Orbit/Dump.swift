import Foundation
import ServiceManagement

/// `Orbit --dump` prints what the panel would show, then exits. Handy for debugging.
enum Dump {
    static func runIfRequested() {
        loginItemCommand()
        guard CommandLine.arguments.contains("--dump") else { return }
        Task.detached {
            let start = Date()
            let claude = await ClaudeProvider.fetch(previous: ProviderSnapshot(id: .claude), logs: ClaudeLogScanner())
            let codex = await CodexProvider.fetch(previous: ProviderSnapshot(id: .codex), logs: CodexLogScanner())
            for s in [claude, codex] { print(describe(s)) }
            print(String(format: "fetched in %.2fs", Date().timeIntervalSince(start)))
            exit(0)
        }
    }

    /// `Orbit --login-item status|on|off`: inspect or change launch-at-login, then exit.
    private static func loginItemCommand() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--login-item") else { return }
        let service = SMAppService.mainApp
        do {
            switch args.dropFirst(i + 1).first {
            case "on": try service.register()
            case "off": try service.unregister()
            default: break
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
        let names: [SMAppService.Status: String] = [.enabled: "enabled", .requiresApproval: "requires approval", .notRegistered: "not registered", .notFound: "not found"]
        print("launch at login: \(names[service.status] ?? "unknown")  (\(Bundle.main.bundlePath))")
        exit(0)
    }

    private static func describe(_ s: ProviderSnapshot) -> String {
        let now = Date()
        var out = ["== \(s.id.displayName)\(s.plan.map { " (\($0))" } ?? "") · health: \(s.health)"]
        for w in s.windows {
            let reset = w.remaining(at: now).map { "resets in \(Fmt.duration($0))" } ?? "no reset"
            out.append("  \(w.label): \(Fmt.percent(w.utilization)) · \(reset)")
        }
        out.append("  source: \(s.limitsLive ? "live" : "logs") · credential: \(s.credential.map { "\($0.source) \($0.hint ?? "") \($0.state)" } ?? "none")")
        let l = s.local
        out.append("  tokens today \(Fmt.compact(l.today.total)) · 5h \(Fmt.compact(l.last5h.total)) · 7d \(Fmt.compact(l.week.total)) · calls today \(l.messagesToday)")
        out.append("  burn \(Fmt.compact(Int(l.burnPerMinute)))/min · cache hit \(l.week.cacheHitRate.map(Fmt.percent) ?? "-") · last activity \(Fmt.ago(l.lastActivity, now: now))")
        out.append("  models: " + l.byModel.prefix(4).map { "\($0.name) \(Fmt.compact($0.tokens))" }.joined(separator: ", "))
        out.append("  projects: " + l.byProject.prefix(4).map { "\($0.name) \(Fmt.compact($0.tokens))" }.joined(separator: ", "))
        out.append("  hourly: " + l.hourly.map { Fmt.compact($0) }.joined(separator: " "))
        for n in s.notes { out.append("  note: \(n)") }
        return out.joined(separator: "\n")
    }
}

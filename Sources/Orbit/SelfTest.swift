import Foundation

/// `Orbit --selftest` checks the response parsers against the documented examples.
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok    " : "FAIL  ") + name)
            if !ok { failures += 1 }
        }
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-09-22T15:00:00Z")!

        // Anthropic cost_report: amounts are cents as decimal strings.
        let anthropic: [String: Any] = ["data": [
            ["starting_at": "2026-09-21T00:00:00Z", "ending_at": "2026-09-22T00:00:00Z",
             "results": [["amount": "250.00", "currency": "USD"], ["amount": "50.50", "currency": "USD"]]],
            ["starting_at": "2026-09-22T00:00:00Z", "ending_at": "2026-09-23T00:00:00Z",
             "results": [["amount": "123.45", "currency": "USD"]]],
            ["starting_at": "2026-09-01T00:00:00Z", "ending_at": "2026-09-02T00:00:00Z", "results": []],
        ], "has_more": false]
        let a = AnthropicCosts.parse(anthropic, now: now)
        check("anthropic today = $1.2345", abs(a.today - 1.2345) < 0.0001)
        check("anthropic month = $4.2395", abs(a.month - 4.2395) < 0.0001)

        // OpenAI costs: amounts are whole units.
        let openai: [String: Any] = ["data": [
            ["start_time": 1790035200, "end_time": 1790121600, "results": [["amount": ["value": 0.06, "currency": "usd"]]]],
            ["start_time": 1789948800, "end_time": 1790035200, "results": [["amount": ["value": 1.5, "currency": "usd"]]]],
        ]]
        let o = OpenAICosts.parse(openai, now: now)
        check("openai today = $0.06", abs(o.today - 0.06) < 0.0001)
        check("openai month = $1.56", abs(o.month - 1.56) < 0.0001)
        check("openai currency usd", o.currency == "usd")

        // Claude Code's saved login.
        let loginJSON = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","refreshToken":"x","expiresAt":4102444800000,"scopes":["user:inference"],"subscriptionType":"max"}}"#
        let login = ClaudeCodeLogin.parse(Data(loginJSON.utf8))
        check("claude code login token", login?.accessToken == "sk-ant-oat01-test")
        check("claude code login plan", login?.plan == "Max")
        check("claude code login not expired", login?.isExpired == false)

        // Key detection.
        check("key: setup token", KeyKind("sk-ant-oat01-abc") == .claudeToken)
        check("key: anthropic admin", KeyKind("sk-ant-admin01-abc") == .anthropicAdmin)
        check("key: anthropic standard rejected", KeyKind("sk-ant-api03-abc").problem != nil)
        check("key: openai admin", KeyKind("sk-admin-abc") == .openAIAdmin)
        check("key: openai project key rejected", KeyKind("sk-proj-abc").problem != nil)

        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

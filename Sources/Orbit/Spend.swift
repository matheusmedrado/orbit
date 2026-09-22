import Foundation

/// API spend from a provider's cost report.
struct Spend: Equatable {
    var today: Double
    var month: Double
    var currency: String

    func format(_ value: Double) -> String {
        value.formatted(.currency(code: currency.uppercased()).precision(.fractionLength(value >= 100 ? 0 : 2)))
    }
}

/// Buckets are daily and in UTC, so "today" and "this month" follow UTC days.
private enum UTCDay {
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func startOfToday(_ now: Date) -> Date { calendar.startOfDay(for: now) }
    static func startOfMonth(_ now: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
    }
}

/// Anthropic Usage & Cost Admin API: GET /v1/organizations/cost_report
enum AnthropicCosts {
    static func fetch(adminKey: String, now: Date = Date()) async throws -> Spend {
        let iso = ISO8601DateFormatter()
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: iso.string(from: UTCDay.startOfMonth(now))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        var req = URLRequest(url: components.url!, timeoutInterval: 20)
        req.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("Orbit (https://github.com/matheusmedrado/orbit)", forHTTPHeaderField: "User-Agent")
        return parse(try await fetchJSON(req), now: now)
    }

    /// Amounts are decimal strings in cents: "123.45" means $1.23.
    static func parse(_ json: [String: Any], now: Date) -> Spend {
        let today = UTCDay.startOfToday(now)
        let iso = ISO8601DateFormatter()
        var spend = Spend(today: 0, month: 0, currency: "USD")
        for bucket in json["data"] as? [[String: Any]] ?? [] {
            let start = (bucket["starting_at"] as? String).flatMap(iso.date(from:))
            let dollars = (bucket["results"] as? [[String: Any]] ?? [])
                .compactMap { ($0["amount"] as? String).flatMap(Double.init) }
                .reduce(0, +) / 100
            spend.month += dollars
            if let start, start >= today { spend.today += dollars }
            if let currency = (bucket["results"] as? [[String: Any]])?.first?["currency"] as? String { spend.currency = currency }
        }
        return spend
    }
}

/// OpenAI Usage API: GET /v1/organization/costs
enum OpenAICosts {
    static func fetch(adminKey: String, now: Date = Date()) async throws -> Spend {
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(UTCDay.startOfMonth(now).timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        var req = URLRequest(url: components.url!, timeoutInterval: 20)
        req.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
        return parse(try await fetchJSON(req), now: now)
    }

    /// Amounts are numbers in whole currency units: 0.06 means $0.06.
    static func parse(_ json: [String: Any], now: Date) -> Spend {
        let today = UTCDay.startOfToday(now).timeIntervalSince1970
        var spend = Spend(today: 0, month: 0, currency: "USD")
        for bucket in json["data"] as? [[String: Any]] ?? [] {
            let start = (bucket as [String: Any]).double("start_time") ?? 0
            let results = bucket["results"] as? [[String: Any]] ?? []
            let value = results.compactMap { $0.dict("amount")?.double("value") }.reduce(0, +)
            spend.month += value
            if start >= today { spend.today += value }
            if let currency = results.first?.dict("amount")?["currency"] as? String { spend.currency = currency }
        }
        return spend
    }
}

private func fetchJSON(_ req: URLRequest) async throws -> [String: Any] {
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw FetchError.failed("no response") }
    if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
    guard http.statusCode == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        throw FetchError.failed(body?.dict("error")?["message"] as? String ?? "HTTP \(http.statusCode)")
    }
    return json
}

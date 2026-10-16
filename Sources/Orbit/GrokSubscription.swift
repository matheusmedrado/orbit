import Foundation
import SQLite3

/// One included-usage window from the Cursor login already on this Mac.
/// The snapshot never contains the access token, cents, sqlite keys, or RPC names.
enum GrokSubscription {
    private static let credentialSource = "Cursor login"
    private static let currencyCode = "USD"
    private static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    /// Previous windows are kept on failure. A non-Grok signup returns a snapshot `isInUse` rejects.
    /// Success builds a new snapshot and does not merge `previous`.
    static func fetch(previous: ProviderSnapshot) async -> ProviderSnapshot {
        let session: Session
        do {
            session = try openSession()
        } catch {
            return apply(.unreadable, previous: previous)
        }
        switch session {
        case .notGrok:
            return hidden()
        case .grokWithoutToken:
            return needsCursor(previous)
        case .grok(let access):
            do {
                async let plan = access.post(.planInfo)
                async let usage = access.post(.periodUsage)
                let meter = try meter(plan: try await plan, usage: try await usage)
                return succeed(meter, now: Date())
            } catch FetchError.unauthorized {
                return apply(.rejected, previous: previous)
            } catch is URLError {
                return apply(.unreachable, previous: previous)
            } catch {
                return apply(.unparsed, previous: previous)
            }
        }
    }

    /// Pure mapping fixtures live next to `meter`. Returns the failure count.
    static func selfTest() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok    " : "FAIL  ") + name)
            if !ok { failures += 1 }
        }

        let past = Date(timeIntervalSince1970: 0)
        let weekly = LimitWindow.includedUsage(
            period: .weekly, included: 20, spent: 5, currencyCode: "USD", resetsAt: past)
        check("weekly fraction 0.25", abs(weekly.utilization - 0.25) < 0.0001)
        check("weekly remaining 15", weekly.allowance?.remaining == 15)
        check("weekly summary", weekly.allowance?.summary == "$15 left of $20")
        check("weekly label", weekly.label == "Weekly")
        check("weekly duration", weekly.duration == 604800)
        check("weekly id", weekly.id == "included")
        check("past reset keeps fraction", weekly.utilization == 0.25)

        let opus = "Claude Opus 5.5 is not included in your weekly usage"
        let spent = succeed(PeriodMeter(
            planName: "SuperGrok", included: 20, spent: 20, currencyCode: "USD",
            period: .weekly, resetsAt: past, percent: nil, displayMessage: opus, enabled: true), now: past)
        let spentWindow = spent.windows.first
        check("spent health", spent.health == .limited(opus))
        check("spent fraction", spentWindow?.utilization == 1)
        check("spent remaining", spentWindow?.allowance?.remaining == 0)

        let warned = succeed(PeriodMeter(
            planName: "SuperGrok", included: 20, spent: 5, currencyCode: "USD",
            period: .weekly, resetsAt: past, percent: nil,
            displayMessage: "Included usage is almost gone.", enabled: true), now: past)
        check("status sentence is not a warning", warned.health == .ok)
        check("warning fraction", warned.windows.first?.utilization == 0.25)

        let excluded = succeed(PeriodMeter(
            planName: "Premium", included: 20, spent: 5, currencyCode: "USD",
            period: .weekly, resetsAt: past, percent: nil,
            displayMessage: opus, enabled: true), now: past)
        check("excluded sentence", excluded.health == .limited(opus))

        let disabled = succeed(PeriodMeter(
            planName: "SuperGrok", included: 20, spent: 5, currencyCode: "USD",
            period: .weekly, resetsAt: past, percent: nil, displayMessage: nil, enabled: false), now: past)
        check("disabled health", disabled.health == .limited("Included usage is turned off."))
        check("disabled window", disabled.windows.count == 1)

        let offPlan: [String: Any] = [
            "planInfo": [
                "planName": "SuperGrok",
                "includedAmountCents": 2000,
                "includedUsagePeriod": "WEEKLY",
                "includedUsageResetsAt": "1800000000000",
            ],
        ]
        let offUsage: [String: Any] = [
            "planUsage": ["includedSpend": 500],
            "enabled": false,
        ]
        if let off = try? meter(
            plan: JSONSerialization.data(withJSONObject: offPlan),
            usage: JSONSerialization.data(withJSONObject: offUsage)) {
            let snap = succeed(off, now: past)
            check("disabled json health", snap.health == .limited("Included usage is turned off."))
            check("disabled json window", snap.windows.count == 1)
        } else {
            check("disabled json health", false)
            check("disabled json window", false)
        }
        check("non-grok signup hidden", hidden().isInUse == false)
        check("grok has no pasted key", ProviderID.grok.facts.pastedKeyTitle == nil)

        let monthly = LimitWindow.includedUsage(
            period: .monthly, included: 20, spent: 5, currencyCode: "USD", resetsAt: past)
        check("monthly duration", monthly.duration == nil)
        check("monthly label", monthly.label == "Monthly")

        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let cycle = "1900000000000"
        let plan: [String: Any] = [
            "planInfo": [
                "planName": "SuperGrok",
                "includedAmountCents": 5000,
                "price": "$200",
                "billingCycleEnd": cycle,
                "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_WEEKLY",
                "includedUsageResetsAt": "1800000000000",
            ],
            "stripeMembershipType": "premium",
        ]
        let usage: [String: Any] = [
            "billingCycleEnd": cycle,
            "planUsage": [
                "includedSpend": 500,
                "limit": 2000,
                "autoPercentUsed": 0.91,
                "totalPercentUsed": 0.91,
            ],
            "enabled": true,
            "displayMessage": "",
        ]
        do {
            let body = try meter(
                plan: JSONSerialization.data(withJSONObject: plan),
                usage: JSONSerialization.data(withJSONObject: usage))
            let snap = succeed(body, now: past)
            let window = snap.windows.first
            check("fixture plan", snap.plan == "SuperGrok")
            check("fixture summary", window?.allowance?.summary == "$15 left of $20")
            check("fixture utilization", window.map { abs($0.utilization - 0.25) < 0.0001 } ?? false)
            check("fixture reset", window?.resetsAt == reset)
            check("fixture has allowance", window?.allowance != nil)
        } catch {
            check("fixture plan", false)
            check("fixture summary", false)
            check("fixture utilization", false)
            check("fixture reset", false)
            check("fixture has allowance", false)
        }

        let percentPlan: [String: Any] = [
            "planInfo": [
                "planName": "Premium",
                "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_WEEKLY",
                "includedUsageResetsAt": "1800000000000",
                "billingCycleEnd": "1900000000000",
            ],
        ]
        let percentUsage: [String: Any] = [
            "planUsage": ["totalPercentUsed": 27.41061755146262, "autoPercentUsed": 27.41061755146262],
            "displayMessage": "You've used 27% of your included usage",
            "enabled": true,
        ]
        do {
            let body = try meter(
                plan: JSONSerialization.data(withJSONObject: percentPlan),
                usage: JSONSerialization.data(withJSONObject: percentUsage))
            let snap = succeed(body, now: past)
            let window = snap.windows.first
            check("percent plan", snap.plan == "Premium")
            check("percent health", snap.health == .ok)
            check("percent utilization", window.map { abs($0.utilization - 0.2741061755146262) < 0.0001 } ?? false)
            check("percent has no dollars", window?.allowance == nil)
            check("percent ignores billing cycle", window?.resetsAt == reset)
        } catch {
            check("percent plan", false)
            check("percent health", false)
            check("percent utilization", false)
            check("percent has no dollars", false)
            check("percent ignores billing cycle", false)
        }

        return failures
    }

    // MARK: Session

    /// Signup type and access token. The refresh token is not a case.
    private enum CursorKey: String, CaseIterable {
        case signUp = "cursorAuth/cachedSignUpType"
        case accessToken = "cursorAuth/accessToken"
    }

    private enum Session {
        case notGrok
        case grokWithoutToken
        case grok(CursorAccess)
    }

    /// Access token for a single fetch. No getter. `post` builds the request and throws it away.
    private struct CursorAccess: CustomStringConvertible {
        private let token: String
        var description: String { "CursorAccess(redacted)" }

        init?(token: String) {
            guard !token.isEmpty else { return nil }
            self.token = token
        }

        func post(_ call: DashboardCall) async throws -> Data {
            guard let url = URL(string: "https://api2.cursor.sh/\(call.rawValue)") else {
                throw FetchError.failed("bad dashboard url")
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = Data("{}".utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FetchError.failed("no response") }
            if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
            guard http.statusCode == 200 else { throw FetchError.failed("HTTP \(http.statusCode)") }
            return data
        }
    }

    private enum DashboardCall: String {
        case planInfo = "aiserver.v1.DashboardService/GetPlanInfo"
        case periodUsage = "aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    }

    /// Readonly, and not an immutable URI, so the open sees Cursor's WAL. Nothing here writes.
    private static func openSession() throws -> Session {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        let rc = sqlite3_open_v2(databaseURL.path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            if let db { sqlite3_close(db) }
            throw FetchError.failed("couldn't open Cursor's database")
        }
        defer { sqlite3_close(opened) }

        let keys = CursorKey.allCases.map(\.rawValue)
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let sql = "SELECT key, value FROM ItemTable WHERE key IN (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(opened, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FetchError.failed("couldn't read Cursor's login")
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, key) in keys.enumerated() {
            _ = key.withCString { cString in
                sqlite3_bind_text(statement, Int32(index + 1), cString, -1, transient)
            }
        }

        var values: [String: String] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw FetchError.failed("couldn't read Cursor's login") }
            guard let keyC = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: keyC)
            if let valueC = sqlite3_column_text(statement, 1) {
                values[key] = String(cString: valueC)
            } else {
                values[key] = ""
            }
        }

        let signup = values[CursorKey.signUp.rawValue] ?? ""
        guard signup.caseInsensitiveCompare("Grok") == .orderedSame else { return .notGrok }
        let token = values[CursorKey.accessToken.rawValue] ?? ""
        guard let access = CursorAccess(token: token) else { return .grokWithoutToken }
        return .grok(access)
    }

    // MARK: Boundary

    /// Validated meter in major units. Cents stop at `requireNonNegative`.
    private struct PeriodMeter: Equatable {
        var planName: String
        var included: Decimal?
        var spent: Decimal?
        var currencyCode: String
        var period: IncludedPeriod
        var resetsAt: Date
        /// 0...1. Used when the payload has a percent and no dollar cap.
        var percent: Double?
        var displayMessage: String?
        var enabled: Bool
    }

    private static func meter(plan: Data, usage: Data) throws -> PeriodMeter {
        let planJSON = try jsonObject(plan)
        let usageJSON = try jsonObject(usage)
        guard let info = object(planJSON, "planInfo", "plan_info") else {
            throw FetchError.failed("missing plan")
        }
        guard let planName = string(info, "planName", "plan_name"), !planName.isEmpty else {
            throw FetchError.failed("missing plan name")
        }
        let period = try periodValue(info["includedUsagePeriod"] ?? info["included_usage_period"])
        guard let resetsAt = timestamp(info, "includedUsageResetsAt", "included_usage_resets_at") else {
            throw FetchError.failed("missing included usage reset")
        }

        let usagePlan = object(usageJSON, "planUsage", "plan_usage")
        // Dollar fields are present on some plans. This Mac's Premium payload has neither,
        // and the upgrade offer's includedAmountCents is a different plan.
        let spent = try dollars(in: usagePlan, keys: "includedSpend", "included_spend")
        let included = try dollars(in: usagePlan, keys: "limit")
            ?? (try dollars(in: info, keys: "includedAmountCents", "included_amount_cents"))
        let percent = fractionPercent(usagePlan, "totalPercentUsed", "total_percent_used")
            ?? fractionPercent(usagePlan, "autoPercentUsed", "auto_percent_used")
        let hasDollars = spent != nil && included != nil
        guard hasDollars || percent != nil else {
            throw FetchError.failed("missing included usage")
        }

        return PeriodMeter(
            planName: planName,
            included: hasDollars ? included : nil,
            spent: hasDollars ? spent : nil,
            currencyCode: currencyCode,
            period: period,
            resetsAt: resetsAt,
            percent: hasDollars ? nil : percent,
            displayMessage: displayMessage(usageJSON),
            enabled: enabled(usageJSON))
    }

    private static func dollars(cents: Decimal) -> Decimal { cents / 100 }

    private static func requireNonNegative(_ cents: Decimal) throws -> Decimal {
        guard cents >= 0 else { throw FetchError.failed("negative usage amount") }
        return dollars(cents: cents)
    }

    private static func period(named raw: String) throws -> IncludedPeriod {
        switch raw.uppercased().split(separator: "_").last.map(String.init) ?? "" {
        case "WEEKLY": .weekly
        case "MONTHLY": .monthly
        default: throw FetchError.failed("unknown included usage period")
        }
    }

    private static func health(for meter: PeriodMeter) -> ProviderHealth {
        let trimmed = meter.displayMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (trimmed?.isEmpty == false) ? trimmed : nil
        let fraction = spentFraction(meter)
        if !meter.enabled {
            return .limited(text ?? "Included usage is turned off.")
        }
        if fraction >= 1 || text?.localizedCaseInsensitiveContains("not included") == true {
            return .limited(text ?? "Included usage is spent. It lifts when the window resets.")
        }
        return .ok
    }

    private static func spentFraction(_ meter: PeriodMeter) -> Double {
        if let included = meter.included, let spent = meter.spent, included > 0 {
            return NSDecimalNumber(decimal: spent / included).doubleValue
        }
        return meter.percent ?? 0
    }

    /// Cursor's `totalPercentUsed` is on a 0...100 scale. 27.41 is 27%, not a fraction.
    private static func fractionPercent(_ json: [String: Any]?, _ keys: String...) -> Double? {
        guard let json else { return nil }
        for key in keys {
            guard let number = decimal(json[key]) else { continue }
            let raw = NSDecimalNumber(decimal: number).doubleValue
            guard raw.isFinite, raw >= 0 else { continue }
            return min(raw / 100, 1)
        }
        return nil
    }

    // MARK: Snapshots

    /// No `previous` parameter, so a success cannot retain stale notes, plan, or windows.
    private static func succeed(_ meter: PeriodMeter, now: Date) -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: .grok)
        snap.plan = meter.planName
        if let included = meter.included, let spent = meter.spent {
            snap.windows = [LimitWindow.includedUsage(
                period: meter.period,
                included: included,
                spent: spent,
                currencyCode: meter.currencyCode,
                resetsAt: meter.resetsAt)]
        } else if let percent = meter.percent {
            snap.windows = [LimitWindow(
                id: LimitWindow.includedUsageID,
                label: meter.period.label,
                utilization: percent,
                resetsAt: meter.resetsAt,
                duration: meter.period.duration)]
        }
        snap.credentials = [CredentialInfo(source: credentialSource, state: .valid)]
        snap.limitsLive = true
        snap.limitsUpdated = now
        snap.health = health(for: meter)
        snap.notes = []
        snap.spend = nil
        return snap
    }

    private enum RefreshFailure {
        case unreachable
        case rejected
        case unreadable
        /// The server answered, and the body was not a meter we know.
        case unparsed
    }

    private static func apply(_ failure: RefreshFailure, previous: ProviderSnapshot) -> ProviderSnapshot {
        switch failure {
        case .unreadable:
            guard !previous.windows.isEmpty else { return previous }
            var snap = previous
            snap.limitsLive = false
            snap.health = .warning("Couldn't read Cursor's login. Showing the last known numbers.")
            return snap
        case .rejected:
            var snap = carried(previous)
            snap.credentials = [CredentialInfo(source: credentialSource, state: .rejected)]
            snap.health = .error("Cursor rejected the login. Open Cursor once, then refresh Orbit.")
            return snap
        case .unreachable:
            return stale(previous, .warning("Couldn't reach Cursor. Showing the last known numbers."))
        case .unparsed:
            return stale(previous, .warning("Couldn't read Cursor's usage. Showing the last known numbers."))
        }
    }

    private static func stale(_ previous: ProviderSnapshot, _ health: ProviderHealth) -> ProviderSnapshot {
        var snap = carried(previous)
        let state = previous.credentials.first { $0.source == credentialSource }?.state ?? .unchecked
        snap.credentials = [CredentialInfo(source: credentialSource, state: state)]
        snap.health = health
        return snap
    }

    private static func carried(_ previous: ProviderSnapshot) -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: .grok)
        snap.plan = previous.plan
        snap.windows = previous.windows
        snap.notes = previous.notes
        snap.limitsUpdated = previous.limitsUpdated
        snap.limitsLive = false
        return snap
    }

    /// Signup is not Grok. Credential `.missing` makes `isInUse` false.
    private static func hidden() -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: .grok)
        snap.credentials = [CredentialInfo(source: credentialSource, state: .missing)]
        return snap
    }

    /// Grok signup, no access token. Keeps previous windows. Credential `.unchecked` leaves the card up.
    private static func needsCursor(_ previous: ProviderSnapshot) -> ProviderSnapshot {
        var snap = carried(previous)
        snap.credentials = [CredentialInfo(source: credentialSource, state: .unchecked)]
        snap.health = .error("Open Cursor so Orbit can read the Grok login.")
        return snap
    }

    // MARK: JSON

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.failed("dashboard response was not an object")
        }
        return json
    }

    private static func object(_ json: [String: Any], _ keys: String...) -> [String: Any]? {
        for key in keys {
            if let value = json[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func string(_ json: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = json[key] as? String { return value }
        }
        return nil
    }

    private static func dollars(in json: [String: Any]?, keys: String...) throws -> Decimal? {
        guard let json else { return nil }
        for key in keys where json[key] != nil {
            guard let cents = decimal(json[key]) else { throw FetchError.failed("bad usage amount") }
            return try requireNonNegative(cents)
        }
        return nil
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        switch value {
        case let number as NSNumber:
            return Decimal(string: number.stringValue)
        case let text as String:
            return Decimal(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    /// Cursor's usage service passes this int64 to `new Date`, so the unit is unix milliseconds.
    private static func timestamp(_ json: [String: Any], _ keys: String...) -> Date? {
        for key in keys {
            guard json[key] != nil, let ms = decimal(json[key]) else { continue }
            let seconds = NSDecimalNumber(decimal: ms / 1000).doubleValue
            guard seconds.isFinite else { continue }
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private static func periodValue(_ value: Any?) throws -> IncludedPeriod {
        switch value {
        case let name as String:
            return try period(named: name)
        case let number as NSNumber:
            switch number.intValue {
            case 2: return .weekly
            case 1: return .monthly
            default: throw FetchError.failed("unknown included usage period")
            }
        default:
            throw FetchError.failed("missing included usage period")
        }
    }

    private static func displayMessage(_ json: [String: Any]) -> String? {
        let raw = string(json, "displayMessage", "display_message")
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// False only when the field is explicitly false. A missing field stays enabled.
    private static func enabled(_ json: [String: Any]) -> Bool {
        guard let value = json["enabled"] else { return true }
        if let flag = value as? Bool { return flag }
        return true
    }
}

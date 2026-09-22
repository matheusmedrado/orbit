import AppKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class UsageStore {
    var claude = ProviderSnapshot(id: .claude)
    var codex = ProviderSnapshot(id: .codex)
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var refreshInterval: TimeInterval
    private(set) var loginItem = LoginItemState.current

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var paused = false
    @ObservationIgnored private let claudeLogs = ClaudeLogScanner()
    @ObservationIgnored private let codexLogs = CodexLogScanner()
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    static let intervals: [TimeInterval] = [30, 60, 120, 300]

    var snapshots: [ProviderSnapshot] { [claude, codex] }

    var severity: IconSeverity {
        let live = snapshots.filter { !$0.windows.isEmpty }
        if live.contains(where: { if case .limited = $0.health { true } else { false } }) { return .critical }
        let peak = live.map(\.peakUtilization).max() ?? 0
        if peak >= 0.9 { return .critical }
        if peak >= 0.75 || claude.credential?.state == .rejected || claude.credential?.state == .missing { return .warning }
        return .normal
    }

    /// Set for a minute after a limit window resets, so the orb can celebrate.
    private(set) var celebrating = false
    @ObservationIgnored private var celebrationTask: Task<Void, Never>?

    /// What the orb's face should look like right now. Status is carried by expression.
    var face: (expression: FaceExpression, palette: OrbPalette) {
        if [.rejected, .missing].contains(claude.credential?.state) { return (.dizzy, .white) }
        if severity == .critical { return (.cross, .red) }
        if celebrating { return (.happy, .white) }
        if severity == .warning { return (.doubtful, .white) }
        let now = Date()
        return snapshots.contains { $0.local.isActive(at: now) } ? (.focused, .white) : (.neutral, .white)
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = saved > 0 ? saved : 60
        scheduleTimer()
        observeSystem()
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < 15 { return }
        isRefreshing = true
        async let c = ClaudeProvider.fetch(previous: claude, logs: claudeLogs)
        async let x = CodexProvider.fetch(previous: codex, logs: codexLogs)
        let (newClaude, newCodex) = await (c, x)
        if Self.didReset(from: claude, to: newClaude) || Self.didReset(from: codex, to: newCodex) {
            celebrate()
        }
        claude = newClaude
        codex = newCodex
        lastRefresh = Date()
        isRefreshing = false
    }

    /// A window reset if its usage dropped noticeably (e.g. 80% -> 0%) since the last live reading.
    private static func didReset(from old: ProviderSnapshot, to new: ProviderSnapshot) -> Bool {
        guard old.limitsLive, new.limitsLive else { return false }
        return new.windows.contains { w in
            guard let before = old.windows.first(where: { $0.id == w.id }) else { return false }
            return before.utilization - w.utilization >= 0.1
        }
    }

    func celebrate(for seconds: Double = 60) {
        celebrationTask?.cancel()
        celebrating = true
        celebrationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.celebrating = false
        }
    }

    func setRefreshInterval(_ seconds: TimeInterval) {
        refreshInterval = seconds
        UserDefaults.standard.set(seconds, forKey: "refreshInterval")
        scheduleTimer()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Orbit: launch-at-login change failed: \(error)")
        }
        loginItem = .current
        if loginItem == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Re-read in case it was changed from System Settings.
    func refreshLoginItem() { loginItem = .current }

    func saveClaudeToken(_ token: String) async -> Bool {
        guard Keychain.saveClaudeToken(token) else { return false }
        await refresh(force: true)
        return true
    }

    // MARK: - Scheduling

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused else { return }
                await self.refresh(force: true)
            }
        }
        t.tolerance = min(10, refreshInterval * 0.1)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Pause while the Mac is asleep or locked; refresh as soon as it's back,
    /// and whenever the panel opens.
    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pause: [(NotificationCenter, Notification.Name)] = [
            (ws, NSWorkspace.willSleepNotification),
            (ws, NSWorkspace.screensDidSleepNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        let resume: [(NotificationCenter, Notification.Name)] = [
            (ws, NSWorkspace.didWakeNotification),
            (ws, NSWorkspace.screensDidWakeNotification),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in pause {
            observe(center, name) { $0.paused = true }
        }
        for (center, name) in resume {
            observe(center, name) { store in
                store.paused = false
                Task { await store.refresh() }
            }
        }
        observe(.default, NSWindow.didBecomeKeyNotification) { store in
            store.refreshLoginItem()
            Task { await store.refresh() }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (UsageStore) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, token))
    }
}

enum LoginItemState {
    case on, needsApproval, off

    static var current: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }
}

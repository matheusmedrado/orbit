import ServiceManagement
import SwiftUI

struct PanelView: View {
    @Environment(UsageStore.self) private var store
    @State private var isVisible = true

    var body: some View {
        // MenuBarExtra only hides its window on close, so stop ticking and
        // animating while the panel is off screen.
        TimelineView(.animation(minimumInterval: 1, paused: !isVisible)) { context in
            VStack(spacing: 10) {
                header(now: context.date)
                ForEach(store.visibleSnapshots, id: \.id) { snapshot in
                    ProviderCard(snapshot: snapshot, now: context.date)
                }
            }
            .padding(12)
        }
        .frame(width: 340)
        .environment(\.panelIsVisible, isVisible)
        .background(VisibilityReader(isVisible: $isVisible))
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            Text("Orbit")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .help("Updated \(Fmt.ago(store.lastRefresh, now: now))")
            if store.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Refresh now (⌘R)")
            .disabled(store.isRefreshing)
            SettingsMenu()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}

private struct SettingsMenu: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        Menu {
            Picker("Refresh every", selection: Binding(get: { store.refreshInterval }, set: { store.setRefreshInterval($0) })) {
                ForEach(UsageStore.intervals, id: \.self) { seconds in
                    Text(seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")").tag(seconds)
                }
            }
            Toggle("Launch at login", isOn: Binding(get: { store.loginItem != .off }, set: { store.setLaunchAtLogin($0) }))
            if store.loginItem == .needsApproval {
                Button("Approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
            }
            Divider()
            Button("Connect Claude…") { store.editingKeyFor = .claude }
            Button("Connect OpenAI…") { store.editingKeyFor = .codex }
            Divider()
            Button("Open Claude logs") { open(".claude/projects") }
            Button("Open Codex sessions") { open(".codex/sessions") }
            Divider()
            Button("Quit Orbit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }

    private func open(_ path: String) {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path))
    }
}

private struct PanelIsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelIsVisible: Bool {
        get { self[PanelIsVisibleKey.self] }
        set { self[PanelIsVisibleKey.self] = newValue }
    }
}

/// Reports whether the hosting window is on screen, from its occlusion state.
private struct VisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.report() }
            report()
        }

        private func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible)
            // Never write SwiftUI state in the middle of a view update.
            DispatchQueue.main.async { self.onChange(visible) }
        }
    }
}

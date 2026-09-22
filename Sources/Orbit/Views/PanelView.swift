import ServiceManagement
import SwiftUI

struct PanelView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 10) {
                header(now: context.date)
                ProviderCard(snapshot: store.claude, now: context.date)
                ProviderCard(snapshot: store.codex, now: context.date)
            }
            .padding(12)
        }
        .frame(width: 340)
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

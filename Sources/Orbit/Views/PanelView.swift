import ServiceManagement
import SwiftUI

struct PanelView: View {
    @Environment(UsageStore.self) private var store
    @UIState private var isVisible = true

    var body: some View {
        // MenuBarExtra only hides its window on close, so stop ticking and
        // animating while the panel is off screen.
        TimelineView(.animation(minimumInterval: 1, paused: !isVisible)) { context in
            VStack(spacing: 10) {
                header(now: context.date)
                // SwiftUI's ScrollView collapses or stretches in a MenuBarExtra
                // window. AppKit sizes to the cards and scrolls past the screen.
                CardListScroll(maxHeight: scrollMaxHeight) {
                    VStack(spacing: 10) {
                        ForEach(store.visibleSnapshots, id: \.key) { snapshot in
                            ProviderCard(snapshot: snapshot, now: context.date)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 340)
        }
        .environment(\.panelIsVisible, isVisible)
        .background(VisibilityReader(isVisible: $isVisible))
    }

    /// Room for the card list under the header, on the screen the pointer is on.
    private var scrollMaxHeight: CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let available = screen?.visibleFrame.height ?? 720
        // Header + padding + a little air under the menu bar.
        return max(200, available - 70)
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

/// Scrolls when the cards are taller than `maxHeight`, otherwise hugs them.
private struct CardListScroll<Content: View>: NSViewRepresentable {
    var maxHeight: CGFloat
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> ScrollBox {
        ScrollBox(maxHeight: maxHeight)
    }

    func updateNSView(_ box: ScrollBox, context: Context) {
        box.maxHeight = maxHeight
        box.setRootView(content())
    }

    final class ScrollBox: NSView {
        var maxHeight: CGFloat {
            didSet { if abs(oldValue - maxHeight) > 0.5 { invalidateIntrinsicContentSize() } }
        }

        private let scroll = NSScrollView()
        private let host = NSHostingView(rootView: AnyView(EmptyView()))
        private var lastContentHeight: CGFloat = 0

        init(maxHeight: CGFloat) {
            self.maxHeight = maxHeight
            super.init(frame: .zero)
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.documentView = host
            addSubview(scroll)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:)") }

        func setRootView<V: View>(_ view: V) {
            host.rootView = AnyView(
                view
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            )
            layoutSubtree()
        }

        override var intrinsicContentSize: NSSize {
            let content = measuredContentHeight()
            return NSSize(width: NSView.noIntrinsicMetric, height: min(content, maxHeight))
        }

        override func layout() {
            super.layout()
            scroll.frame = bounds
            layoutSubtree()
        }

        private func layoutSubtree() {
            let width = max(bounds.width, 316)
            let height = measuredContentHeight()
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            if abs(lastContentHeight - height) > 0.5 {
                lastContentHeight = height
                invalidateIntrinsicContentSize()
                // The menu bar window keeps a tall frame after a card closes.
                DispatchQueue.main.async { [weak self] in self?.fitWindow() }
            }
            scroll.layoutSubtreeIfNeeded()
        }

        private func measuredContentHeight() -> CGFloat {
            let width = max(bounds.width, 316)
            // Give the hosting view room, then ask how tall the cards want to be.
            let previous = host.frame
            host.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
            host.layoutSubtreeIfNeeded()
            let fitted = host.fittingSize.height
            host.frame = previous
            if fitted > 1, fitted < 9_999 { return fitted }
            return max(lastContentHeight, 1)
        }

        private func fitWindow() {
            guard let window else { return }
            invalidateIntrinsicContentSize()
            let hostView = sequence(first: self as NSView, next: \.superview).reversed().first {
                String(describing: type(of: $0)).contains("HostingView")
            }
            hostView?.invalidateIntrinsicContentSize()
            let height = hostView?.fittingSize.height ?? fittingSize.height
            guard height > 40 else { return }
            var frame = window.frame
            guard abs(frame.height - height) > 1 else { return }
            let top = frame.maxY
            frame.size.height = height
            frame.origin.y = top - height
            window.setFrame(frame, display: true, animate: false)
        }
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
            ForEach(ProviderID.allCases) { id in
                if let title = id.facts.pastedKeyTitle {
                    Button(title) { store.editingKeyFor = id }
                }
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

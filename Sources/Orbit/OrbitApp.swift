import SwiftUI

@main
struct OrbitApp: App {
    @State private var store = UsageStore()
    @State private var animator = FaceAnimator()

    init() {
        Dump.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(store)
                .environment(animator)
        } label: {
            let face = store.face
            Image(nsImage: OrbFace.image(size: 18, expression: face.expression, lid: animator.lid,
                                         outline: true, tint: face.palette == .red ? .systemRed : nil))
                .accessibilityLabel("Orbit")
                .onAppear { Snapshot.runIfRequested(store: store, animator: animator) }
        }
        .menuBarExtraStyle(.window)
    }
}

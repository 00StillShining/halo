import SwiftUI

/// Root layout. This turn: top status strip + the reactive EP-40 stage filling the
/// window. The contextual right rail and the bottom mode bar arrive as Play/Load
/// are built out toward the Phase 1 gate.
struct HaloRootView: View {
    @Environment(HaloAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HaloStatusBar(
                isPlaceholder: model.scene.isPlaceholder,
                deviceStatus: model.deviceStatus,
                firmwareStatus: model.firmwareStatus,
                usbStatus: model.usbStatus,
                displayStatus: model.displayStatus,
                isDisplayLive: model.isDisplayLive,
                midiEndpointName: model.midiEndpointName
            )
            EP40StageView(controller: model.scene)
        }
        .haloPalette(model.palette)
        .background(HaloColorTokens.tokens(for: model.palette).canvas)
        .onAppear {
            model.startEP40Monitoring()
        }
        .task(id: displayLifecycle) {
            await model.runDisplayPreview(
                isSceneActive: displayLifecycle.isSceneActive,
                reduceMotion: displayLifecycle.reduceMotion
            )
        }
    }

    private var displayLifecycle: DisplayLifecycleKey {
        DisplayLifecycleKey(
            feed: model.displayFeedMode,
            isSceneActive: scenePhase == .active,
            reduceMotion: reduceMotion
        )
    }
}

private struct DisplayLifecycleKey: Equatable {
    let feed: EP40DisplayFeedMode
    let isSceneActive: Bool
    let reduceMotion: Bool
}

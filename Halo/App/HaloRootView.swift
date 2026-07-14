import SwiftUI
import UniformTypeIdentifiers

/// Root layout (Brief §7): top status strip + the reactive EP-40 stage + a
/// contextual right rail (collapsible in Play, ~34–40% in data-heavy modes) +
/// a bottom mode bar. A mode change animates the rail width and glides the
/// camera — the stage keeps the model centred in its own shrinking viewport, so
/// the screen is re-framed, never replaced.
struct HaloRootView: View {
    @Environment(HaloAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        return ZStack {
            mainLayout
            preparationOverlay
        }
        .haloPalette(model.palette)
    }

    private var mainLayout: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            HaloStatusBar(
                isPlaceholder: model.scene.isPlaceholder,
                deviceStatus: model.deviceStatus,
                firmwareStatus: model.firmwareStatus,
                usbStatus: model.usbStatus,
                displayStatus: model.displayStatus,
                isDisplayLive: model.isDisplayLive,
                midiEndpointName: model.midiEndpointName,
                ringState: model.ringState,
                lifecyclePhase: model.lifecyclePhase,
                palette: model.palette,
                onSelectPalette: { model.selectPalette($0) }
            )
            GeometryReader { geo in
                HStack(spacing: 0) {
                    EP40StageView(controller: model.scene)
                    HaloRailView(mode: model.mode,
                                 isPlayCollapsed: $model.isPlayRailCollapsed)
                        .frame(width: railWidth(total: geo.size.width))
                }
                .animation(reduceMotion ? nil
                           : .easeInOut(duration: HaloMechanics.modeChangeDuration),
                           value: railAnimationKey)
            }
            HaloModeBar(mode: model.mode,
                        visibleModes: HaloMode.visible(rackAvailable: model.rackAvailable),
                        onSelect: { model.select($0) })
        }
        .haloPalette(model.palette)
        .focusEffectDisabled()
        .background(HaloColorTokens.tokens(for: model.palette).canvas)
        .onKeyPress(.escape) {
            model.transients.handleEscape() ? .handled : .ignored
        }
        .onAppear {
            model.scene.setReduceMotion(reduceMotion)
            model.startEP40Monitoring()
            model.startAudioDeviceDiscovery()
            model.startLifecycleObservers()
        }
        .onChange(of: reduceMotion) { _, newValue in
            model.scene.setReduceMotion(newValue)
        }
        // Resilience (Brief §8): a hidden/suspended app can miss Note Offs (App Nap),
        // so drop every visually pressed key on background — never a stuck pad. Also
        // re-read mic permission on return (it may have changed in System Settings).
        .onChange(of: scenePhase) { _, newValue in
            switch newValue {
            case .background: model.handleSceneBackgrounded()
            case .active:     model.permission.refresh()
            default:          break
            }
        }
        .task(id: displayLifecycle) {
            await model.runDisplayPreview(
                isSceneActive: displayLifecycle.isSceneActive,
                reduceMotion: displayLifecycle.reduceMotion
            )
        }
        // Global Finder drop (Brief §7): the stage delegate wins over the model
        // area; this catches drops on the rail / status / mode bar and opens the
        // prep sheet with no pad preselected.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            let load = model.load   // capture the Sendable value, not the @Environment wrapper
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    load.beginPreparation(fileURL: url, padHint: nil)
                }
            }
            return true
        }
    }

    /// The preparation sheet, presented as a custom transient over everything
    /// (Brief §7). A dimmed scrim cancels on tap; Escape cancels via the transient
    /// stack inside `PreparationSheet`.
    @ViewBuilder
    private var preparationOverlay: some View {
        if model.load.prep != nil {
            let c = HaloColorTokens.tokens(for: model.palette)
            c.ink.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { model.load.cancelPreparation() }
            PreparationSheet(session: model.load)
        }
    }

    /// Rail width policy: Play collapses to a thin spine or a light utility
    /// column; every other mode takes a clamped data-heavy fraction of the window.
    private func railWidth(total: CGFloat) -> CGFloat {
        if model.mode == .play {
            return model.isPlayRailCollapsed ? HaloMetrics.railSpineWidth
                                             : HaloMetrics.railPlayWidth
        }
        return HaloMetrics.dataRailWidth(total: total)
    }

    /// Drives the single shared width animation — changes when the mode or the
    /// Play collapse state changes.
    private var railAnimationKey: RailAnimationKey {
        RailAnimationKey(mode: model.mode, isPlayCollapsed: model.isPlayRailCollapsed)
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

private struct RailAnimationKey: Equatable {
    let mode: HaloMode
    let isPlayCollapsed: Bool
}

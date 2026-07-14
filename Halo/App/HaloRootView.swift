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
            diagnosticsOverlay
            chopOverlay
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
                isDiagnosticsOpen: model.isDiagnosticsOpen,
                onSelectPalette: { model.selectPalette($0) },
                onOpenDiagnostics: { toggleDiagnostics() }
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
        // ⌘D toggles the Diagnostics drawer (DD-024). A hidden keyboard-shortcut
        // button is the sanctioned way to bind a modifier chord app-wide; it never
        // takes focus or paints.
        .background {
            Button("", action: toggleDiagnostics)
                .keyboardShortcut("d", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // ⌘M toggles the monitor route (Brief §7 lists ⌘M; it was previously
        // unbound). Same hidden-shortcut pattern as ⌘D. `toggleMonitor` is a no-op
        // when neither running nor startable, so the chord never fakes a route.
        .background {
            Button("", action: { model.toggleMonitor() })
                .keyboardShortcut("m", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // ⌘G grabs the recent past into a loop take (Brief §5b). Same hidden-shortcut
        // pattern as ⌘M/⌘D. `grabLoop` is a no-op when no route runs, so the chord
        // never fabricates a take.
        .background {
            Button("", action: { model.grabLoop() })
                .keyboardShortcut("g", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onKeyPress(.escape) {
            model.transients.handleEscape() ? .handled : .ignored
        }
        // Space-to-audition (Brief §7): only in Edit, only with a selection, and never
        // while the rename field is focused (it consumes Space to type). Escape must NOT
        // stop audition — the transient stack above is left untouched.
        .onKeyPress(.space) {
            // Not while a CHOP surface is open — it owns the keyboard for slice audition.
            guard !model.chop.isOpen,
                  EditSession.shouldAudition(mode: model.mode,
                                             isRenaming: model.edit.isRenaming,
                                             hasSelection: model.edit.selectedAssetID != nil)
            else { return .ignored }
            model.toggleAudition()
            return .handled
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
        // Global Finder drop (Brief §7), mode-aware: in EDIT a drop imports into the
        // local library (DD-022); otherwise it opens the LOAD prep sheet with no pad
        // preselected. Mode-gating the root handler keeps the Load prep-sheet from
        // hijacking a drop while the user is editing.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            if model.mode == .edit {
                guard !providers.isEmpty else { return false }
                let edit = model.edit
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in await edit.import(urls: [url]) }
                    }
                }
                return true
            }
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

    /// The Diagnostics drawer (DD-024), presented as a right-anchored transient over
    /// everything. A dimmed scrim cancels on tap; Escape cancels via the transient
    /// stack inside `DiagnosticsDrawer`. It holds no audio handle (DD-013).
    @ViewBuilder
    private var diagnosticsOverlay: some View {
        if model.isDiagnosticsOpen {
            let c = HaloColorTokens.tokens(for: model.palette)
            c.ink.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { toggleDiagnostics() }
            DiagnosticsDrawer()
                .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The CHOP surface (Brief §5c, DD-030), presented as a custom transient over
    /// everything — identical scrim pattern to `preparationOverlay`. A dimmed scrim
    /// cancels on tap; Escape cancels via the transient stack inside `ChopSurface`.
    @ViewBuilder
    private var chopOverlay: some View {
        if model.chop.isOpen {
            let c = HaloColorTokens.tokens(for: model.palette)
            c.ink.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { model.closeChop() }
            ChopSurface()
        }
    }

    /// Toggle the drawer, animating the slide unless Reduce Motion is on. Wrapping
    /// the state change here keeps the single animation policy in one place.
    private func toggleDiagnostics() {
        withAnimation(reduceMotion ? nil
                      : .easeInOut(duration: HaloMechanics.modeChangeDuration)) {
            model.toggleDiagnostics()
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

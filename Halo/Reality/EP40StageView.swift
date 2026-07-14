import SwiftUI
import RealityKit
import UniformTypeIdentifiers

/// The permanent stage: graph-paper canvas + a soft grounding shadow + the
/// reactive EP-40 `RealityView`. The model is the visual centre in every mode
/// (Brief §4). On macOS the `RealityView` closures receive
/// `RealityViewCameraContent`; there is no `attachments:` initializer here.
struct EP40StageView: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var controller: EP40SceneController

    var body: some View {
        GeometryReader { geo in
            ZStack {
                GridCanvas()

                // 2D grounding shadow beneath the device (Brief §6 "soft grounding
                // shadow"). Kept in SwiftUI for controllable luminance.
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [c.ink.opacity(0.28), c.ink.opacity(0.0)],
                            center: .center, startRadius: 2,
                            endRadius: min(geo.size.width, geo.size.height) * 0.34
                        )
                    )
                    .frame(width: geo.size.width * 0.52, height: geo.size.height * 0.24)
                    .offset(y: geo.size.height * 0.16)
                    .blur(radius: 12)

                RealityView { content in
                    let world = await controller.makeScene()
                    content.add(world)
                    // Drive the halo-ring animation and pad-LED decay off the
                    // render loop, not a timer. Both early-out at ~zero cost when
                    // nothing is animating.
                    controller.ringSubscription = content.subscribe(
                        to: SceneEvents.Update.self
                    ) { event in
                        MainActor.assumeIsolated {
                            controller.frameTick(deltaTime: Float(event.deltaTime))
                        }
                    }
                    Task { @MainActor [weak controller] in
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        controller?.activateDisplayStreaming()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // File drops on the model's numeric pads preselect the pad and
                // open the preparation sheet (Brief §7). The reticle tracks the
                // hovered pad — halo presentation, never a hardware claim.
                .onDrop(of: [.fileURL],
                        delegate: StageDropDelegate(scene: controller,
                                                    session: model.load,
                                                    viewSize: geo.size))

                // Coarse app-state layer (Brief §7 P4). Anchored bottom-leading above
                // the mode bar so the model stays the visual centre (Brief §10). Driven
                // STRICTLY by `lifecyclePhase` + `loadPhase` (both already honest) so it
                // can never contradict the status-bar chips or invent a device state.
                // Silent on the happy path (.ready / .live). DD-026.
                EP40StageStateLayer(
                    lifecycle: model.lifecyclePhase,
                    loadPhase: controller.loadPhase,
                    onRetry: { model.retryMIDIObservation() })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(HaloMetrics.s3)
                .transition(reduceMotion ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity))
                .animation(reduceMotion ? nil : .easeInOut(duration: HaloMechanics.modeChangeDuration),
                           value: stateLayerKey)
            }
        }
    }

    /// Changes only on a coarse-state transition, so the plate eases in/out once per
    /// real change (never per frame). Reduce Motion collapses it to a cross-fade.
    private var stateLayerKey: StageStateKey {
        StageStateKey(lifecycle: model.lifecyclePhase, loadPhase: controller.loadPhase)
    }
}

private struct StageStateKey: Equatable {
    let lifecycle: HaloLifecyclePhase
    let loadPhase: EP40SceneController.LoadPhase
}

/// The coarse-state plate for the hero stage. A pure function of two already-honest
/// signals — it holds no audio/MIDI handle and makes no device claim. On `.waiting`
/// it labels the disconnected PREVIEW loop ("SHOWING PREVIEW"), which STRENGTHENS
/// provenance honesty (DD-014): the demo now says it is a demo.
private struct EP40StageStateLayer: View {
    let lifecycle: HaloLifecyclePhase
    let loadPhase: EP40SceneController.LoadPhase
    let onRetry: () -> Void

    var body: some View {
        Group {
            if loadPhase == .loading {
                HaloStatePlate(kind: .loading, title: "LOADING MODEL",
                               reason: "PREPARING THE EP-40 STAGE.")
            } else {
                switch lifecycle {
                case .starting:
                    HaloStatePlate(kind: .loading, title: "STARTING",
                                   reason: "BRINGING UP MIDI + AUDIO.")
                case .waiting:
                    HaloStatePlate(kind: .disconnected, title: "NO EP-40",
                                   reason: "CONNECT BY USB-C AND POWER ON. SHOWING PREVIEW.")
                case .suspended:
                    HaloStatePlate(kind: .suspended, title: "ASLEEP",
                                   reason: "SYSTEM SUSPENDED — INPUTS RELEASED.")
                case let .error(label):
                    HaloStatePlate(kind: .error, title: "ERROR · \(label)",
                                   reason: "MIDI CLIENT COULD NOT START.",
                                   actionLabel: "RETRY",
                                   actionHelp: "Restart MIDI observation",
                                   action: onRetry)
                case .ready, .live:
                    EmptyView()          // happy path — the plate stays silent
                }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
    }
}

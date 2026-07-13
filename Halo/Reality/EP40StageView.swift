import SwiftUI
import RealityKit

/// The permanent stage: graph-paper canvas + a soft grounding shadow + the
/// reactive EP-40 `RealityView`. The model is the visual centre in every mode
/// (Brief §4). On macOS the `RealityView` closures receive
/// `RealityViewCameraContent`; there is no `attachments:` initializer here.
struct EP40StageView: View {
    @Environment(\.halo) private var c
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
            }
        }
    }
}

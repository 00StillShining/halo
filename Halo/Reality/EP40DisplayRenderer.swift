import CoreGraphics
import CoreImage
import Metal
import RealityKit
import os
import simd

/// Owns the one runtime texture used by the replica's display. Frames are
/// coalesced so a slow GPU upload can never build an animation backlog.
@MainActor
final class EP40DisplayRenderer {
    private static let log = Logger(subsystem: "studios.meremortal.halo", category: "display")
    private static let width = 1_024
    private static let height = 289
    private static let textureOptions = TextureResource.CreateOptions(
        semantic: .color,
        compression: .none,
        mipmapsMode: .none
    )

    private let modelEntity: Entity
    private let baseImage: CGImage?
    private let highlightImage: CGImage?
    private var texture: TextureResource?
    private var drawableQueue: TextureResource.DrawableQueue?
    private var pendingState: EP40DisplayState?
    private var updateTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    init?(displaySurface: Entity) {
        guard let modelEntity = Self.firstModelEntity(in: displaySurface) else {
            Self.log.error("display_surface has no ModelComponent descendant")
            return nil
        }
        self.modelEntity = modelEntity
        let baseImage = EP40DisplayArtwork.makeBaseImage()
        self.baseImage = baseImage
        self.highlightImage = Self.makeIndicatorLayer(from: baseImage)
    }

    func install(initial state: EP40DisplayState) async {
        guard let image = makeFrame(state) else {
            Self.log.error("Could not draw the initial EP-40 display frame")
            return
        }

        do {
            let texture = try await TextureResource(
                image: image,
                withName: "halo_ep40_live_display",
                options: Self.textureOptions
            )
            var material = UnlitMaterial(texture: texture)
            material.faceCulling = .none

            guard var model = modelEntity.components[ModelComponent.self] else {
                Self.log.error("Resolved display mesh lost its ModelComponent")
                return
            }
            let slotCount = max(model.mesh.expectedMaterialCount, 1)
            model.materials = Array(
                repeating: material as any RealityKit.Material,
                count: slotCount
            )
            modelEntity.components.set(model)
            self.texture = texture
            Self.log.info("Installed live unlit texture on display_surface (\(slotCount) material slot(s))")

            if let pendingState, pendingState != state {
                self.pendingState = nil
                submit(pendingState)
            }
        } catch {
            Self.log.error("Could not install EP-40 display texture: \(error.localizedDescription)")
        }
    }

    /// Drawable queues only become consumable after RealityKit is rendering the
    /// material. The stage calls this on the next run-loop turn after attaching
    /// the world, avoiding a queue/bootstrap stall.
    func activateStreaming() {
        guard drawableQueue == nil, let texture else { return }
        do {
            let drawableQueue = try TextureResource.DrawableQueue(
                .init(
                    pixelFormat: .rgba8Unorm_srgb,
                    width: Self.width,
                    height: Self.height,
                    usage: [.shaderRead],
                    mipmapsMode: .none,
                    timeout: .milliseconds(16)
                )
            )
            drawableQueue.allowsNextDrawableTimeout = true
            texture.replace(withDrawables: drawableQueue)
            self.drawableQueue = drawableQueue
            submit(pendingState ?? .previewStill)
        } catch {
            Self.log.error("Could not start EP-40 drawable stream: \(error.localizedDescription)")
        }
    }

    func submit(_ state: EP40DisplayState) {
        pendingState = state
        guard drawableQueue != nil, updateTask == nil else { return }

        updateTask = Task { @MainActor [weak self] in
            self?.drainPendingFrames()
        }
    }

    private func drainPendingFrames() {
        defer { updateTask = nil }

        while let state = pendingState {
            pendingState = nil
            guard let drawableQueue, let image = makeFrame(state) else { continue }
            do {
                try present(image, on: drawableQueue)
            } catch {
                pendingState = pendingState ?? state
                scheduleRetry()
                Self.log.debug("EP-40 display drawable temporarily unavailable: \(error.localizedDescription)")
                return
            }
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard let self else { return }
            retryTask = nil
            if let pendingState { submit(pendingState) }
        }
    }

    private func present(_ image: CGImage, on queue: TextureResource.DrawableQueue) throws {
        guard let providerData = image.dataProvider?.data else {
            throw EP40DisplayRendererError.missingPixelData
        }
        let data = providerData as Data
        let drawable = try queue.nextDrawable()
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else {
                throw EP40DisplayRendererError.missingPixelData
            }
            drawable.texture.replace(
                region: MTLRegionMake2D(0, 0, Self.width, Self.height),
                mipmapLevel: 0,
                withBytes: address,
                bytesPerRow: image.bytesPerRow
            )
        }
        drawable.present()
    }

    private static func firstModelEntity(in entity: Entity) -> Entity? {
        if entity.components[ModelComponent.self] != nil { return entity }
        for child in entity.children {
            if let found = firstModelEntity(in: child) { return found }
        }
        return nil
    }

    // MARK: - Pixel renderer

    private func makeFrame(_ uncheckedState: EP40DisplayState) -> CGImage? {
        var state = uncheckedState
        state.clamp()

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Self.width,
                height: Self.height,
                bitsPerComponent: 8,
                bytesPerRow: Self.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let canvas = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        context.setFillColor(Self.screenGreen)
        context.fill(canvas)

        // Top-left pixel coordinates match the authored PNG and the mapping
        // measurements in the model contract.
        context.translateBy(x: 0, y: CGFloat(Self.height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high

        if let baseImage {
            context.saveGState()
            context.setAlpha(state.feedMode == .waiting ? 0.16 : 0.27)
            drawAtlasUpright(baseImage, in: context)
            context.restoreGState()

            let indicators = highlightImage ?? baseImage
            highlight(Self.modeRects[state.mode.rawValue], from: indicators, in: context)

            if state.isPlaying {
                highlight(CGRect(x: 485, y: 165, width: 48, height: 56), from: indicators, in: context)
            }
            if state.clockPulse {
                highlight(CGRect(x: 650, y: 56, width: 69, height: 66), from: indicators, in: context)
            }
            if let group = state.activeGroup {
                highlight(Self.groupRects[group], from: indicators, in: context)
            }
            if state.activePadIndex != nil {
                highlight(CGRect(x: 596, y: 164, width: 49, height: 59), from: indicators, in: context)
            }
        }

        drawDigits(state.value, in: context, brightness: state.feedMode == .waiting ? 0.64 : 1)
        drawPadActivity(state.activePadIndex, velocity: state.velocity, in: context)
        drawMeters(left: state.leftMeter, right: state.rightMeter, in: context)
        drawFeedBeacon(state.feedMode, pulse: state.clockPulse, in: context)

        return context.makeImage()
    }

    private func highlight(_ rect: CGRect, from image: CGImage, in context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.setAlpha(1)
        context.setShadow(offset: .zero, blur: 4, color: Self.glow)
        drawAtlasUpright(image, in: context)
        context.restoreGState()
    }

    /// The renderer uses top-left coordinates for procedural overlays. Core
    /// Graphics image draws need one local counter-flip inside that coordinate
    /// system so the authored atlas and the vector digits share an orientation.
    private func drawAtlasUpright(_ image: CGImage, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(Self.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        context.restoreGState()
    }

    /// Removes the atlas's flat green background once, leaving a transparent
    /// icon layer that can glow without revealing rectangular crop boundaries.
    private static func makeIndicatorLayer(from image: CGImage?) -> CGImage? {
        guard let image else { return nil }
        let dimension = 32
        let background = SIMD3<Float>(46 / 255, 170 / 255, 130 / 255)
        var cube = [Float]()
        cube.reserveCapacity(dimension * dimension * dimension * 4)

        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let rgb = SIMD3<Float>(
                        Float(red) / Float(dimension - 1),
                        Float(green) / Float(dimension - 1),
                        Float(blue) / Float(dimension - 1)
                    )
                    let distance = simd_distance(rgb, background)
                    let alpha = min(max((distance - 0.035) / 0.12, 0), 1)
                    cube.append(rgb.x * alpha)
                    cube.append(rgb.y * alpha)
                    cube.append(rgb.z * alpha)
                    cube.append(alpha)
                }
            }
        }

        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        let cubeData = cube.withUnsafeBytes { Data($0) }
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: output.extent)
    }

    private func drawDigits(_ value: Int, in context: CGContext, brightness: CGFloat) {
        let panel = CGRect(x: 447, y: 64, width: 183, height: 93)
        context.saveGState()
        context.setFillColor(Self.digitWell)
        context.fill(panel)
        context.setStrokeColor(Self.segmentGhost)
        context.setLineWidth(2)
        context.stroke(panel.insetBy(dx: 1, dy: 1))

        let digits = [value / 100, (value / 10) % 10, value % 10]
        for (index, digit) in digits.enumerated() {
            drawSevenSegment(
                digit,
                origin: CGPoint(x: 457 + index * 55, y: 72),
                brightness: brightness,
                in: context
            )
        }
        context.restoreGState()
    }

    private func drawSevenSegment(
        _ digit: Int,
        origin: CGPoint,
        brightness: CGFloat,
        in context: CGContext
    ) {
        // Segment order: top, upper-right, lower-right, bottom,
        // lower-left, upper-left, middle.
        let active: Set<Int> = switch digit {
        case 0: [0, 1, 2, 3, 4, 5]
        case 1: [1, 2]
        case 2: [0, 1, 3, 4, 6]
        case 3: [0, 1, 2, 3, 6]
        case 4: [1, 2, 5, 6]
        case 5: [0, 2, 3, 5, 6]
        case 6: [0, 2, 3, 4, 5, 6]
        case 7: [0, 1, 2]
        case 8: [0, 1, 2, 3, 4, 5, 6]
        default: [0, 1, 2, 3, 5, 6]
        }

        let segments = [
            CGRect(x: origin.x + 7,  y: origin.y,      width: 30, height: 7),
            CGRect(x: origin.x + 37, y: origin.y + 6,  width: 7,  height: 29),
            CGRect(x: origin.x + 37, y: origin.y + 39, width: 7,  height: 29),
            CGRect(x: origin.x + 7,  y: origin.y + 67, width: 30, height: 7),
            CGRect(x: origin.x,      y: origin.y + 39, width: 7,  height: 29),
            CGRect(x: origin.x,      y: origin.y + 6,  width: 7,  height: 29),
            CGRect(x: origin.x + 7,  y: origin.y + 33, width: 30, height: 7),
        ]

        for (index, rect) in segments.enumerated() {
            let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            context.addPath(path)
            context.setFillColor(active.contains(index) ? Self.segmentLit(alpha: brightness) : Self.segmentGhost)
            if active.contains(index) {
                context.setShadow(offset: .zero, blur: 5, color: Self.glow)
            } else {
                context.setShadow(offset: .zero, blur: 0)
            }
            context.fillPath()
        }
        context.setShadow(offset: .zero, blur: 0)
    }

    private func drawPadActivity(_ activePad: Int?, velocity: Float, in context: CGContext) {
        let origin = CGPoint(x: 601, y: 168)
        let size = CGSize(width: 8, height: 9)
        let gap = CGSize(width: 3, height: 3)

        for index in 0..<12 {
            let column = index % 3
            let row = index / 3
            let rect = CGRect(
                x: origin.x + CGFloat(column) * (size.width + gap.width),
                y: origin.y + CGFloat(row) * (size.height + gap.height),
                width: size.width,
                height: size.height
            )
            let isActive = index == activePad
            context.setFillColor(isActive ? Self.segmentLit(alpha: 0.65 + CGFloat(velocity) * 0.35) : Self.segmentGhost)
            if isActive { context.setShadow(offset: .zero, blur: 6, color: Self.glow) }
            context.fill(rect)
            context.setShadow(offset: .zero, blur: 0)
        }
    }

    private func drawMeters(left: Float, right: Float, in context: CGContext) {
        let repaint = CGRect(x: 989, y: 58, width: 35, height: 220)
        context.setFillColor(Self.digitWell)
        context.fill(repaint)

        let levels = [left, right, left * 0.78, right * 0.78]
        let bankY: [CGFloat] = [63, 119, 174, 230]
        for (bank, level) in levels.enumerated() {
            for segment in 0..<3 {
                let threshold = Float(segment + 1) / 3
                let lit = level >= threshold
                let rect = CGRect(x: 994, y: bankY[bank] + CGFloat((2 - segment) * 15), width: 30, height: 11)
                context.setFillColor(lit ? Self.segmentLit(alpha: 0.94) : Self.segmentGhost)
                if lit { context.setShadow(offset: .zero, blur: 4, color: Self.glow) }
                context.fill(rect)
                context.setShadow(offset: .zero, blur: 0)
            }
        }
    }

    private func drawFeedBeacon(_ mode: EP40DisplayFeedMode, pulse: Bool, in context: CGContext) {
        // Small Halo-owned provenance mark: one dot for preview, two for wait,
        // three for event-backed live. It stays inside an otherwise empty gap.
        let count = switch mode { case .preview: 1; case .waiting: 2; case .live: 3 }
        for index in 0..<3 {
            let rect = CGRect(x: 878 + index * 10, y: 274, width: 6, height: 6)
            let lit = index < count
            context.setFillColor(lit ? Self.segmentLit(alpha: pulse ? 1 : 0.76) : Self.segmentGhost)
            context.fillEllipse(in: rect)
        }
    }

    private static let modeRects = [
        CGRect(x: 204, y: 210, width: 113, height: 70),
        CGRect(x: 376, y: 210, width: 99, height: 70),
        CGRect(x: 539, y: 210, width: 113, height: 70),
        CGRect(x: 652, y: 210, width: 124, height: 70),
        CGRect(x: 761, y: 210, width: 114, height: 70),
    ]

    private static let groupRects = [
        CGRect(x: 39,  y: 55, width: 52, height: 61),
        CGRect(x: 96,  y: 55, width: 52, height: 61),
        CGRect(x: 151, y: 55, width: 52, height: 61),
        CGRect(x: 207, y: 55, width: 52, height: 61),
    ]

    private static let screenGreen = CGColor(red: 0.045, green: 0.37, blue: 0.25, alpha: 1)
    private static let digitWell = CGColor(red: 0.025, green: 0.20, blue: 0.13, alpha: 0.96)
    private static let segmentGhost = CGColor(red: 0.20, green: 0.39, blue: 0.30, alpha: 0.72)
    private static let glow = CGColor(red: 0.76, green: 1.0, blue: 0.82, alpha: 0.75)

    private static func segmentLit(alpha: CGFloat) -> CGColor {
        CGColor(red: 0.90, green: 0.98, blue: 0.91, alpha: alpha)
    }
}

private enum EP40DisplayRendererError: Error {
    case missingPixelData
}

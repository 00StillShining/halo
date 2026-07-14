import AVFoundation
import Foundation

/// LOCAL sample audition (Brief §7 "Space-to-audition"). Plays a prepared+treated
/// buffer to the SYSTEM DEFAULT output via `AVAudioEngine` + `AVAudioPlayerNode` —
/// ordinary file preview, like QuickLook. It is DELIBERATELY separate from the EP-40
/// monitor AUHAL route (DD-017) and claims nothing about the device (DD-022 honesty):
/// auditioning a local file says nothing about any hardware slot or the device output.
///
/// No custom render callback exists here — we hand a prebuilt buffer to `scheduleBuffer`
/// and `AVAudioEngine` owns its own audio thread — so none of the RT-callback rules
/// (Brief §2) apply. The playhead progress is derived from the node's real render clock,
/// so it never fakes motion (Brief §1/§4).
@MainActor
@Observable
final class AuditionPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private(set) var isPlaying = false
    private(set) var playingAssetID: UUID?
    /// 0…1 through the auditioned window, for the waveform playhead. Rests at 0.
    private(set) var progress: Double = 0

    private var frames = 0
    private var poll: Task<Void, Never>?

    init() { engine.attach(player) }

    /// Play `buffer` (a fully-prepared local window). Reconnects the player each time
    /// because the treatment rate varies per audition. Honest no-op if the engine
    /// cannot start. `loops` seamlessly repeats the buffer (GRAB loop audition, §5b) —
    /// the grab was zero-cross-trimmed at bar boundaries, so the seam is click-free;
    /// the natural-end completion is suppressed while looping.
    func play(_ buffer: AVAudioPCMBuffer, assetID: UUID, loops: Bool = false) {
        stop()
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        guard (try? engine.start()) != nil else { return }   // honest failure: nothing plays
        frames = Int(buffer.frameLength)
        guard frames > 0 else { engine.stop(); return }

        let options: AVAudioPlayerNodeBufferOptions = loops ? [.loops] : []
        player.scheduleBuffer(buffer, at: nil, options: options) { [weak self] in
            // Completion fires off the main actor — hop back before touching state.
            // A looping buffer only completes on stop(), so ignore it there.
            guard !loops else { return }
            Task { @MainActor in self?.finishNatural(assetID) }
        }
        player.play()
        isPlaying = true
        playingAssetID = assetID
        progress = 0
        startPolling()
    }

    /// Stop immediately and reset the transport (Escape must NOT call this — Brief §7).
    func stop() {
        poll?.cancel()
        poll = nil
        if player.isPlaying { player.stop() }
        if engine.isRunning { engine.stop() }
        isPlaying = false
        playingAssetID = nil
        progress = 0
        frames = 0
    }

    /// Natural end of the scheduled buffer. Ignore stale completions from a previous take.
    private func finishNatural(_ assetID: UUID) {
        guard isPlaying, playingAssetID == assetID else { return }
        stop()
    }

    /// ~30 Hz playhead driven by the node's real render clock, wall-clock-free.
    private func startPolling() {
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.isPlaying {
                if let node = self.player.lastRenderTime,
                   let t = self.player.playerTime(forNodeTime: node), self.frames > 0 {
                    self.progress = min(1, max(0, Double(t.sampleTime) / Double(self.frames)))
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    // MARK: - Buffer construction (pure)

    /// Build a non-interleaved Float32 `AVAudioPCMBuffer` from per-channel float arrays.
    /// Pure and Sendable-safe to call from any actor. Returns nil for an empty signal.
    nonisolated static func makeBuffer(channels: [[Float]], sampleRate: Double) -> AVAudioPCMBuffer? {
        let channelCount = channels.count
        let n = channels.first?.count ?? 0
        guard channelCount > 0, n > 0, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channelCount),
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(n)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(n)
        for c in 0..<channelCount {
            let count = min(n, channels[c].count)
            channels[c].withUnsafeBufferPointer { src in
                if let base = src.baseAddress { data[c].update(from: base, count: count) }
            }
        }
        return buffer
    }
}

import AudioToolbox
import Foundation
import Synchronization   // macOS 26 target — Atomic is available

/// The shared, preallocated real-time state for one running monitor route. It is
/// created ONCE when a route starts and handed (as an unretained pointer) to both
/// the input and output render callbacks, so nothing on the audio thread allocates,
/// locks, logs or retains a Swift object (Brief §8).
///
/// Data flow:
///   input AUHAL → `inputRender` writes interleaved stereo into `ringBuffer`
///   output AUHAL → `outputRender` reads from `ringBuffer`, then runs the chain:
///     monitor gain → (Phase 5 FX insert, bypassed & bit-transparent) → −1 dBFS
///     limiter → device. Levels are published to `meter` and `levelBridge`.
///
/// The UI never touches this object except through the atomic `gainTargetBits`
/// seam; the render thread owns the mutable DSP structs (`gain`, `limiter`).
final class MonitorRenderContext: @unchecked Sendable {
    /// Canonical interleaved Float32 stereo format (both callbacks share it, so the
    /// ring is a plain float bridge and the converter stage is passthrough).
    let format: AudioStreamBasicDescription
    let maxFrames: Int
    let channelCount = 2

    /// The SPSC bridge from input callback to output callback.
    let ringBuffer: AudioRingBuffer

    /// Preallocated buffer list the input callback renders the EP-40 into before
    /// copying to the ring. One interleaved stereo AudioBuffer.
    let inputScratch: UnsafeMutableAudioBufferListPointer
    private let inputScratchData: UnsafeMutableRawPointer

    /// The input unit the input callback pulls from (set by the router once created).
    var inputUnit: AudioUnit?

    // MARK: DSP chain (render-thread owned)
    var gain: MonitorGain
    var limiter: SafetyLimiter
    /// Phase 5a dub FX rack (Brief §5a). Inserted between gain and limiter; when the
    /// master is disengaged and settled it is bit-transparent (the NULL TEST). The
    /// render thread owns this object; the UI only crosses the atomic `rackParams`
    /// seam. Nil `rackParams` (no rack attached to the route) skips it entirely.
    let rack: DubRack
    let rackParams: RackParameters?

    let meter: AudioMeter
    let levelBridge: AudioLevelBridge

    /// Optional RAW-input recorder tap (P2-recorder). When present AND armed, the
    /// input callback best-effort-writes the same pre-gain/pre-limiter samples it
    /// bridges to the monitor into the tap's own ring, and publishes raw peaks.
    /// Nil when no recorder is attached; a single relaxed atomic load per block when
    /// attached but not armed.
    let captureTap: CaptureTap?

    /// Always-on rolling raw-input capture (P5b-grab). The input callback writes the
    /// SAME raw pre-gain/pre-limiter/pre-FX stream it bridges to the monitor into this
    /// ring UNCONDITIONALLY while a route runs, so GRAB can freeze the recent past.
    /// Nil when no grab buffer is attached; a single masked copy per block otherwise.
    let rollingGrab: RollingCaptureBuffer?

    /// UI→RT gain bridge: linear amplitude bit-pattern, written by the main actor,
    /// read once per output block. Lock-free (Brief §8).
    let gainTargetBits: Atomic<UInt32>

    init(sampleRate: Double, maxFrames: Int, initialGainDB: Double,
         levelBridge: AudioLevelBridge, captureTap: CaptureTap? = nil,
         rackParams: RackParameters? = nil, rollingGrab: RollingCaptureBuffer? = nil) {
        self.maxFrames = maxFrames
        self.levelBridge = levelBridge
        self.captureTap = captureTap
        self.rackParams = rackParams
        self.rollingGrab = rollingGrab

        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mChannelsPerFrame = 2
        asbd.mBitsPerChannel = 32
        asbd.mBytesPerFrame = 8       // 2 ch × 4 bytes, interleaved
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerPacket = 8
        format = asbd

        // Ring holds ~8× the largest block so a scheduling hiccup never underruns.
        ringBuffer = AudioRingBuffer(minimumCapacity: maxFrames * 2 * 8)

        gain = MonitorGain(db: initialGainDB, sampleRate: sampleRate)
        limiter = SafetyLimiter(sampleRate: sampleRate)
        rack = DubRack(sampleRate: sampleRate, maxFrames: max(maxFrames, 512))
        meter = AudioMeter(sampleRate: sampleRate)
        gainTargetBits = Atomic<UInt32>(MonitorGain.linear(fromDB: initialGainDB).bitPattern)

        // One interleaved stereo scratch buffer, sized to the largest block.
        let byteCount = maxFrames * 2 * MemoryLayout<Float>.size
        inputScratchData = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<Float>.alignment)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        list[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(byteCount),
            mData: inputScratchData)
        inputScratch = list
    }

    deinit {
        inputScratchData.deallocate()
        free(inputScratch.unsafeMutablePointer)
    }

    /// Set the monitor gain target (dBFS) from the UI. Lock-free.
    func setGainTargetDB(_ db: Double) {
        gainTargetBits.store(MonitorGain.linear(fromDB: db).bitPattern, ordering: .relaxed)
    }
}

// MARK: - Real-time render callbacks (C function pointers, capture nothing)

/// Output AUHAL render callback: pull the bridged input, run the chain, publish
/// meters. Real-time-safe.
func monitorOutputRender(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ctx = Unmanaged<MonitorRenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ioData else { return noErr }
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    guard let raw = abl[0].mData else { return noErr }
    let out = raw.assumingMemoryBound(to: Float.self)
    let frames = Int(inNumberFrames)
    let needed = frames * ctx.channelCount

    // Pull the bridged input; fill any shortfall with silence (underrun → no click).
    let got = ctx.ringBuffer.read(into: out, count: needed)
    if got < needed {
        (out + got).update(repeating: 0, count: needed - got)
    }

    // Chain: monitor gain → dub FX rack (Phase 5a, bit-transparent when bypassed)
    // → −1 dBFS limiter.
    ctx.gain.setTargetLinear(Float(bitPattern: ctx.gainTargetBits.load(ordering: .relaxed)))
    ctx.gain.processStereo(out, frames: frames)
    // FX insert (Brief §5a): post-gain / pre-limiter. When the master is disengaged
    // and settled this is a bit-transparent no-op (the NULL TEST).
    if let rackParams = ctx.rackParams {
        ctx.rack.process(out, frames: frames, params: rackParams)
    }

    // PRINT FX (Brief §7): when the recorder is armed in post-FX mode, tap the
    // post-rack / pre-limiter signal here into the recorder's OWN ring. Mutually
    // exclusive with the input callback's raw write (postFX is set before arming and
    // never flips mid-take), so the SPSC ring keeps a single producer. RT-safe: two
    // relaxed loads when idle; a preallocated ring write + peak publish when active.
    if let tap = ctx.captureTap,
       tap.armed.load(ordering: .relaxed), tap.postFX.load(ordering: .relaxed) {
        tap.ring.write(out, count: needed)
        tap.meter.publish(out, frames: frames)
    }

    // Raw (pre-limiter) peaks: the only place clip can be judged honestly — the
    // limiter caps the buffer at −1 dBFS, so post-limiter peaks never reach 1.0.
    let rawPeakL = MeterMath.peak(out, frames: frames, stride: 2, channel: 0)
    let rawPeakR = MeterMath.peak(out, frames: frames, stride: 2, channel: 1)
    ctx.limiter.processStereo(out, frames: frames)

    // Publish levels (post-chain) for the meter and the ring glow; clip from the
    // raw peaks above.
    ctx.meter.publish(out, frames: frames, rawPeakL: rawPeakL, rawPeakR: rawPeakR)
    let peak = MeterMath.peak(out, frames: frames, stride: 1, channel: 0)
    ctx.levelBridge.publish(peak: min(1, peak))
    return noErr
}

/// Input AUHAL render callback: render the EP-40 input into scratch, copy to the
/// ring. Real-time-safe.
func monitorInputRender(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ctx = Unmanaged<MonitorRenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = ctx.inputUnit else { return noErr }
    let frames = Int(inNumberFrames)
    let needed = frames * ctx.channelCount

    // Reset the scratch buffer size to this block before rendering into it.
    ctx.inputScratch[0].mDataByteSize = UInt32(needed * MemoryLayout<Float>.size)
    let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber,
                                 inNumberFrames, ctx.inputScratch.unsafeMutablePointer)
    guard status == noErr, let raw = ctx.inputScratch[0].mData else { return status }

    let src = raw.assumingMemoryBound(to: Float.self)
    // Best-effort write; if the consumer is momentarily behind we drop the overflow
    // rather than block (Brief §8: callbacks never block).
    ctx.ringBuffer.write(src, count: needed)

    // P5b-grab: always-rolling raw capture. Unconditional while the route runs — the
    // ring overwrites its own oldest frames — so GRAB can always freeze the recent
    // past. RT-safe: a preallocated masked copy + one release store, no branch on any
    // UI flag (the buffer is the single fixed producer, this callback).
    ctx.rollingGrab?.write(src, frames: frames)

    // P2-recorder: tap the RAW pre-monitor stream (before gain/limiter/FX) into the
    // recorder's OWN ring when armed AND not in PRINT FX mode (post-FX is produced by
    // the output callback instead — DD). One relaxed atomic load when idle; both
    // calls below are RT-safe (preallocated ring write + peak-only meter publish).
    if let tap = ctx.captureTap,
       tap.armed.load(ordering: .relaxed), !tap.postFX.load(ordering: .relaxed) {
        tap.ring.write(src, count: needed)
        tap.meter.publish(src, frames: frames)
    }
    return noErr
}

import Synchronization   // macOS 26 target — Atomic is available

/// Always-on rolling capture of the RAW pre-monitor input (Brief §5b GRAB). One
/// fixed producer = the input AUHAL callback; the main actor is the sole reader,
/// via a seqlock-validated snapshot (never on the audio thread). Overwrites oldest
/// frames continuously while a route runs. RT-safe: preallocated, one relaxed load +
/// masked copy + one release store per block; no alloc/lock/log/retain (Brief §8).
///
/// HONESTY (Brief §1/§4): the ring only ever fills from the live input callback, so
/// it holds nothing but real captured audio. `resetSession()` at route start plants a
/// `floor` frame so a grab can never reach audio from a previous session, and
/// `snapshot` refuses (returns false) any window the producer overran mid-copy — a
/// torn loop is dropped, never returned as a real grab.
///
/// It captures the RAW input (pre-gain / pre-limiter / pre-FX), fed from
/// `monitorInputRender` only. A rack-engaged grab is therefore still a clean raw
/// loop. A PRINT-FX (post-rack) grab is deferred (DD-029): an always-on ring cannot
/// switch producers between the input and output callbacks live without breaking the
/// single-producer contract, and a silent post-FX grab would be dishonest.
final class RollingCaptureBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>   // interleaved stereo
    let capacityFrames: Int                            // power of two
    private let frameMask: Int
    /// Absolute monotonic stereo-frame count ever written (producer owns; reader acquires).
    private let writeFrames = Atomic<Int>(0)
    /// Grabs may not reach before this (set at route start so a new session is clean).
    private let floorFrames = Atomic<Int>(0)

    /// Margin so the producer never overwrites frames mid-copy on the reader.
    static let guardFrames = 4_096

    init(seconds: Double = 60, referenceRate: Double = 48_000) {
        let wantFrames = Int((seconds * referenceRate).rounded())
        var cap = 2
        while cap < wantFrames { cap <<= 1 }
        capacityFrames = cap
        frameMask = cap - 1
        storage = .allocate(capacity: cap * 2)
        storage.initialize(repeating: 0, count: cap * 2)
    }

    deinit {
        storage.deinitialize(count: capacityFrames * 2)
        storage.deallocate()
    }

    /// PRODUCER (input callback, RT). `src` interleaved stereo, `frames` stereo frames.
    /// RT-safe: one relaxed load, a masked copy (≤ two runs across the wrap) and one
    /// release store. No allocation, lock, log or Swift-object retain.
    func write(_ src: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let w = writeFrames.load(ordering: .relaxed)          // producer-owned
        let start = (w & frameMask)
        let firstFrames = min(frames, capacityFrames - start)
        storage.advanced(by: start * 2).update(from: src, count: firstFrames * 2)
        if firstFrames < frames {
            storage.update(from: src.advanced(by: firstFrames * 2),
                           count: (frames - firstFrames) * 2)
        }
        writeFrames.store(w + frames, ordering: .releasing)
    }

    /// Reader "now" anchor (main actor): the absolute frame count written so far.
    var nowFrame: Int { writeFrames.load(ordering: .acquiring) }

    /// Plant the resident floor at the current write head so grabs after a fresh
    /// route start can never reach audio captured in a previous session.
    func resetSession() {
        floorFrames.store(writeFrames.load(ordering: .acquiring), ordering: .releasing)
    }

    var floor: Int { floorFrames.load(ordering: .acquiring) }

    /// Oldest frame currently resident and safe to read (never before this session's
    /// floor, and inside the guard margin the producer keeps ahead of the reader).
    var oldestResidentFrame: Int {
        max(floor, nowFrame - capacityFrames + Self.guardFrames)
    }

    /// Copy absolute window [startFrame,endFrame) into `dst` (interleaved). Seqlock:
    /// returns false if the producer overran our oldest read during the copy (so a
    /// torn loop is refused, never returned as a real grab), or if the requested
    /// window is out of the resident range. CONSUMER (main actor) thread only.
    func snapshot(startFrame: Int, endFrame: Int, into dst: inout [Float]) -> Bool {
        let n = endFrame - startFrame
        guard n > 0, n * 2 <= dst.count else { return false }
        let w0 = writeFrames.load(ordering: .acquiring)
        guard endFrame <= w0, startFrame >= max(floor, w0 - capacityFrames) else { return false }
        dst.withUnsafeMutableBufferPointer { d in
            guard let base = d.baseAddress else { return }
            var f = startFrame, o = 0
            while f < endFrame {
                let idx = (f & frameMask)
                let run = min(endFrame - f, capacityFrames - idx)
                (base + o * 2).update(from: storage + idx * 2, count: run * 2)
                f += run
                o += run
            }
        }
        let w1 = writeFrames.load(ordering: .acquiring)
        return (w1 - startFrame) <= capacityFrames    // oldest read still intact
    }
}

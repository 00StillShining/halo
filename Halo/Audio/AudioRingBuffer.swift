import Synchronization   // macOS 26 target — Atomic is available

/// A preallocated, lock-free single-producer/single-consumer float ring buffer
/// (Brief §8: "Bridge audio input to output through a preallocated
/// single-producer/single-consumer ring buffer").
///
/// The input AUHAL render callback is the sole PRODUCER; the output render
/// callback is the sole CONSUMER. Both run on real-time audio threads, so every
/// operation here is allocation-free, lock-free and never retains/releases a Swift
/// object, logs, or touches SwiftUI (Brief §8 real-time rules). Correctness relies
/// on exactly one writer and one reader — never call `write` from two threads or
/// `read` from two threads.
///
/// Indices are monotonically increasing 64-bit counters masked into the storage;
/// the difference `write - read` is the current fill, which cannot exceed the
/// capacity. A `release` store on the producer side pairs with an `acquire` load
/// on the consumer side (and vice-versa) so published samples are visible before
/// the index that exposes them.
final class AudioRingBuffer: @unchecked Sendable {
    /// Interleaved float storage. Capacity is rounded up to a power of two so the
    /// wrap is a cheap mask rather than a modulo.
    private let storage: UnsafeMutablePointer<Float>
    /// Number of Float slots (power of two).
    let capacity: Int
    private let mask: Int

    /// Total floats ever written (producer-owned monotonic counter).
    private let writeIndex = Atomic<Int>(0)
    /// Total floats ever read (consumer-owned monotonic counter).
    private let readIndex = Atomic<Int>(0)

    /// `capacity` is the requested minimum number of Float slots; the real
    /// capacity is the next power of two ≥ that (and ≥ 2). Allocation happens once,
    /// here — never in a render callback.
    init(minimumCapacity: Int) {
        let wanted = max(2, minimumCapacity)
        var cap = 1
        while cap < wanted { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        storage = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        storage.initialize(repeating: 0, count: cap)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Floats available to read right now (consumer view). Safe to call from the
    /// consumer thread; a concurrent write only ever makes this larger.
    var availableToRead: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed)
    }

    /// Floats that can be written right now (producer view). A concurrent read only
    /// ever makes this larger.
    var availableToWrite: Int {
        capacity - (writeIndex.load(ordering: .relaxed) - readIndex.load(ordering: .acquiring))
    }

    /// Copy up to `count` floats from `src` into the buffer. Returns the number
    /// actually written (`< count` when the buffer is nearly full — the caller is
    /// responsible for tolerating an overrun, never blocking). PRODUCER thread only.
    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let w = writeIndex.load(ordering: .relaxed)
        let free = capacity - (w - readIndex.load(ordering: .acquiring))
        let toWrite = min(count, free)
        guard toWrite > 0 else { return 0 }

        let start = w & mask
        let firstChunk = min(toWrite, capacity - start)
        storage.advanced(by: start).update(from: src, count: firstChunk)
        if firstChunk < toWrite {
            storage.update(from: src.advanced(by: firstChunk), count: toWrite - firstChunk)
        }
        writeIndex.store(w + toWrite, ordering: .releasing)
        return toWrite
    }

    /// Copy up to `count` floats into `dst`. Returns the number actually read
    /// (`< count` when the buffer underruns — the caller must fill the remainder
    /// with silence, never block). CONSUMER thread only.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let r = readIndex.load(ordering: .relaxed)
        let filled = writeIndex.load(ordering: .acquiring) - r
        let toRead = min(count, filled)
        guard toRead > 0 else { return 0 }

        let start = r & mask
        let firstChunk = min(toRead, capacity - start)
        dst.update(from: storage.advanced(by: start), count: firstChunk)
        if firstChunk < toRead {
            dst.advanced(by: firstChunk).update(from: storage, count: toRead - firstChunk)
        }
        readIndex.store(r + toRead, ordering: .releasing)
        return toRead
    }

    /// Discard all buffered samples (consumer side). Used when (re)starting a route
    /// so a stale burst never plays. Not real-time-called; safe at engine setup.
    func drain() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}

import Foundation

/// One planned pad write in a CHOP → pads transaction (Brief §5c). Pure preview data:
/// slot numbers walk the MOCK next-free set, bytes are REAL arithmetic on the treated
/// slice. Nothing here touches a device — the whole transaction is disabled (Phase 0B).
struct ChopPadWrite: Sendable, Equatable {
    let sliceIndex: Int          // 0-based slice id
    let group: Int               // 0…3 = A…D
    let gridIndex: Int           // 0…11 pad grid index
    let proposedSlot: SampleSlotID
    let name: String             // "AMEN.01"
    let payloadBytes: Int        // frames × channels × 2 at the chosen treatment (REAL)
}

/// A pure preview of the serialized upload+assign transaction (Brief §5c). It reports
/// which pads/slots each slice would occupy, the total payload bytes, and the resulting
/// MOCK free space — plus any overflow (slices that ran past the last pad, reported and
/// NEVER wrapped). The device execution is a disabled seam (`ChopSending`).
struct SendToPadsPlan: Sendable, Equatable {
    let writes: [ChopPadWrite]
    let overflowCount: Int           // slices with no pad from the chosen start
    let totalBytes: Int
    let freeBeforeBytes: Int
    let group: Int
    let startGridIndex: Int

    var placedCount: Int { writes.count }
    var freeAfterBytes: Int { freeBeforeBytes - totalBytes }
    var fits: Bool { overflowCount == 0 && freeAfterBytes >= 0 }

    /// Pad grid index of the last placed slice, if any.
    var lastGridIndex: Int? { writes.last?.gridIndex }
    /// Slot span of the placed writes, as `(first, last)` raw slot numbers.
    var slotSpan: (first: SampleSlotID, last: SampleSlotID)? {
        guard let f = writes.first?.proposedSlot, let l = writes.last?.proposedSlot else { return nil }
        return (f, l)
    }
}

/// Pure planner. Slices fill `startGridIndex…11` in the chosen group, in order; overflow
/// is reported, never wrapped. Slot numbers walk the MOCK library's next-free ascending
/// set. Bytes use the REAL treated frame count × channels × 2. Names are `base.NN`
/// (1-based). Deterministic ⇒ unit-tested.
enum ChopPlanner {

    static func plan(slices: [SliceRange],
                     channelCount: Int,
                     treatment: SampleTreatment,
                     sourceRate: Double,
                     group: Int,
                     startGridIndex: Int,
                     baseName: String,
                     library: MockDeviceLibrary) -> SendToPadsPlan {
        let padsPerGroup = EP40MIDIMapping.padsPerGroup
        let start = min(max(startGridIndex, 0), padsPerGroup)
        let capacity = max(0, padsPerGroup - start)
        let placeable = min(slices.count, capacity)
        let overflow = slices.count - placeable
        let channels = max(0, channelCount)

        // Walk the mock next-free slot set ascending, consuming one per placed slice.
        var used = Set(library.sounds.map { $0.slot.raw })
        var nextCandidate = 1

        func nextFreeSlot() -> SampleSlotID? {
            while nextCandidate <= 999 {
                defer { nextCandidate += 1 }
                if !used.contains(nextCandidate), let slot = SampleSlotID(nextCandidate) {
                    used.insert(nextCandidate)
                    return slot
                }
            }
            return nil
        }

        var writes: [ChopPadWrite] = []
        var total = 0
        let cleanBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let base = cleanBase.isEmpty ? "CHOP" : cleanBase

        for i in 0..<placeable {
            guard let slot = nextFreeSlot() else { break }   // library full → stop honestly
            let slice = slices[i]
            let outFrames = treatment.outputFrameCount(sourceFrameCount: slice.frameCount,
                                                       sourceSampleRate: sourceRate)
            let bytes = SampleMemoryEstimator.payloadBytes(frames: outFrames, channels: channels)
            total += bytes
            writes.append(ChopPadWrite(
                sliceIndex: slice.id,
                group: group,
                gridIndex: start + i,
                proposedSlot: slot,
                name: String(format: "%@.%02d", base, i + 1),
                payloadBytes: bytes))
        }

        return SendToPadsPlan(writes: writes,
                              overflowCount: overflow,
                              totalBytes: total,
                              freeBeforeBytes: library.freeBytes,
                              group: group,
                              startGridIndex: start)
    }
}

// MARK: - Device execution seam (NEEDS-DEVICE, Phase 0B)

/// The serialized upload+assign transaction the SEND panel *models* but never runs.
/// Mirrors `BackupRestoring`/`DeviceUnavailableRestorer`: the only reachable result today
/// is `.needsDevice`. The `.partial` case shapes the future abort path (a truthful partial
/// report), and is present so the interface is complete — it is not produced yet.
protocol ChopSending: Sendable {
    func send(_ plan: SendToPadsPlan) async -> ChopSendResult
}

enum ChopSendResult: Equatable, Sendable {
    case needsDevice(reason: String)
    case completed(written: Int)
    case partial(written: Int, failedAt: Int, recoveryNote: String)
}

/// The default sender — honestly refuses. Writing samples onto the EP-40 is the
/// proprietary protocol (Phase 0B); no bytes are invented and nothing is sent.
struct DeviceUnavailableChopSender: ChopSending {
    func send(_ plan: SendToPadsPlan) async -> ChopSendResult {
        .needsDevice(reason: "DEVICE TRANSFER — NEEDS VERIFIED PROTOCOL (PHASE 0B)")
    }
}

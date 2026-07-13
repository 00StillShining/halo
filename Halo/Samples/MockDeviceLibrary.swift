import Foundation

/// MOCK — deterministic stand-in for device state (Brief §3). Never populated
/// from, and never claiming, a real EP-40. Every UI surface showing these values
/// must carry the MOCK provenance tag. Seed-determinism is a hard requirement: the
/// loop's headless screenshots must be byte-stable run to run, so nothing here may
/// use `Date()`, `UUID()`, or unseeded randomness — only `SplitMix64`.
struct MockDeviceLibrary: Sendable, Equatable {
    /// The full 001–999 storage library, ascending by slot.
    let sounds: [MockDeviceSound]
    /// The one loaded project whose 4×12 pad assignments reference a subset of slots.
    let project: MockProject

    /// MOCK device-reported capacity (Brief §3 "prefer device-reported values" —
    /// this models the *report*, it is not a hard UI constant). 128 MB nominal,
    /// ~122 MB usable per firmware notes.
    static let reportedCapacityBytes = 122_000_000

    /// The ONE mock instance the whole UI reads. Fixed seed → stable screenshots.
    static let standard = generate(seed: 0x0E40)

    /// Σ of every stored sound's bytes. Derived, never stored.
    var usedBytes: Int { sounds.reduce(0) { $0 + $1.bytes } }
    /// Free = reported capacity − used. `usedBytes + freeBytes == reportedCapacityBytes`
    /// holds by construction (pinned by `MockDeviceLibraryTests`).
    var freeBytes: Int { Self.reportedCapacityBytes - usedBytes }

    /// Every project pad that references a given slot. This one function is the
    /// structural anti-conflation guarantee: the SOUNDS "USE" column is *computed
    /// from* PADS data through here, so slots and pads can never silently disagree.
    func assignments(referencing slot: SampleSlotID) -> [MockPadAssignment] {
        project.assignments.filter { $0.slot == slot }
    }

    func sound(for slot: SampleSlotID) -> MockDeviceSound? {
        sounds.first { $0.slot == slot }
    }

    // MARK: - Deterministic generator

    static func generate(seed: UInt64) -> MockDeviceLibrary {
        var rng = SplitMix64(state: seed)
        let names = ["KICK", "SNARE", "HAT", "CLAP", "PERC",
                     "BASS", "STAB", "VOX", "FX", "AMEN CHOP"]
        let rates = [46875, 44100, 32000, 26250, 22050]

        // Walk 001…999 and admit ~15% of slots — ascending, so `sounds` is sorted.
        // Exactly one admission draw per slot keeps the stream deterministic.
        var sounds: [MockDeviceSound] = []
        for n in 1...999 {
            guard rng.next() % 1000 < 150, let slot = SampleSlotID(n) else { continue }
            let name = names[Int(rng.next() % UInt64(names.count))]
            let idx = Int(rng.next() % 100)
            let dur = 0.2 + Double(rng.next() % 3300) / 1000.0        // 0.2 … 3.5 s
            let rate = rates[Int(rng.next() % UInt64(rates.count))]
            let channels = (rng.next() % 3 == 0) ? 1 : 2             // ~1/3 mono
            let bytes = Int((dur * Double(rate) * Double(channels) * 2).rounded())
            sounds.append(MockDeviceSound(
                slot: slot,
                name: "\(name) \(String(format: "%02d", idx))",
                durationSeconds: dur, sampleRate: rate,
                channels: channels, bytes: bytes))
        }

        // 4 groups × 12 pads, physical grid order. ~62% assigned; the rest nil.
        var assignments: [MockPadAssignment] = []
        for group in 0..<EP40MIDIMapping.groupCount {
            for gridIndex in 0..<EP40MIDIMapping.padsPerGroup {
                let assign = (rng.next() % 100 < 62) && !sounds.isEmpty
                let slot: SampleSlotID? = assign
                    ? sounds[Int(rng.next() % UInt64(sounds.count))].slot
                    : nil
                assignments.append(MockPadAssignment(
                    group: group, gridIndex: gridIndex, slot: slot))
            }
        }
        return MockDeviceLibrary(
            sounds: sounds,
            project: MockProject(name: "DRUM TOOLS", assignments: assignments))
    }
}

/// SplitMix64 — a tiny, portable, seeded PRNG. Same output on every machine and
/// run given the same seed, which is exactly what deterministic mock data needs.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A device storage slot number, 001…999. NOT a pad (Brief §3). Labelled `SLOT 042`.
struct SampleSlotID: Hashable, Comparable, Sendable {
    let raw: Int
    /// Validated: only 1…999 are addressable slots.
    init?(_ raw: Int) {
        guard (1...999).contains(raw) else { return nil }
        self.raw = raw
    }
    var label: String { String(format: "%03d", raw) }
    static func < (a: SampleSlotID, b: SampleSlotID) -> Bool { a.raw < b.raw }
}

/// One stored sound in the device library. All fields are MOCK.
struct MockDeviceSound: Identifiable, Sendable, Equatable {
    let slot: SampleSlotID
    let name: String                      // "KICK 22", "AMEN CHOP 04"…
    let durationSeconds: Double
    let sampleRate: Int                   // 46875 / 44100 / 32000 / 26250 / 22050
    let channels: Int                     // 1 | 2
    let bytes: Int
    var id: SampleSlotID { slot }
}

/// A project pad assignment. References a slot; it never IS a slot (Brief §3).
/// Labelled `PAD 7 · GROUP A`.
struct MockPadAssignment: Sendable, Equatable {
    let group: Int                        // 0…3 == A…D (matches EP40MIDIMapping.group)
    let gridIndex: Int                    // 0…11, EP40Entity.padGridOrder space
    let slot: SampleSlotID?               // nil = unassigned
}

/// A mock project: exactly 48 assignments (4 groups × 12), in grid order.
struct MockProject: Sendable, Equatable {
    let name: String                      // "DRUM TOOLS"
    let assignments: [MockPadAssignment]

    func assignment(group: Int, gridIndex: Int) -> MockPadAssignment {
        assignments[group * EP40MIDIMapping.padsPerGroup + gridIndex]
    }
}

// MARK: - Shared physical-board layout (single source of truth)

/// The numeric-pad legends in physical 3×4 grid order, and group letters. Derived
/// from `EP40Entity.padGridOrder` so the board, the SOUNDS "USE" column, travel and
/// display can never disagree — `PadsBoardTests` zips `legends` against
/// `padGridOrder` to keep them locked.
enum PadGrid {
    static let legends = ["7", "8", "9", "4", "5", "6", "1", "2", "3", ".", "0", "ENTER"]
    static func groupLetter(_ group: Int) -> String {
        guard (0..<4).contains(group) else { return "?" }
        return ["A", "B", "C", "D"][group]
    }
    /// Compact usage token for a pad assignment, e.g. `A7`, `B3`, `D.`.
    static func useToken(_ a: MockPadAssignment) -> String {
        groupLetter(a.group) + legends[a.gridIndex]
    }
}

// MARK: - Deterministic MOCK formatting

/// Pure display formatters for mock device values. Decimal (SI) byte units to read
/// like device-reported figures; no locale, no `Date`.
enum MockFormat {
    static func bytes(_ n: Int) -> String {
        n >= 1_000_000
            ? String(format: "%.1f MB", Double(n) / 1_000_000)
            : "\(Int((Double(n) / 1000).rounded())) KB"
    }
    static func bytesCompact(_ n: Int) -> String {
        n >= 1_000_000
            ? String(format: "%.1fM", Double(n) / 1_000_000)
            : "\(Int((Double(n) / 1000).rounded()))K"
    }
    static func megabytes(_ n: Int) -> String {
        String(format: "%.1f MB", Double(n) / 1_000_000)
    }
    static func duration(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = Int(total) % 60
        let tenths = Int((total - total.rounded(.down)) * 10) % 10
        return String(format: "%d:%02d.%d", minutes, secs, tenths)
    }
    static func rate(_ hz: Int) -> String { String(format: "%.1fK", Double(hz) / 1000) }
    static func channels(_ count: Int) -> String { count >= 2 ? "ST" : "MO" }
    static func channelsLong(_ count: Int) -> String { count >= 2 ? "STEREO" : "MONO" }
}

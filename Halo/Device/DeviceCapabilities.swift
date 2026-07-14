import Foundation

/// Hardware truth for one EP-40 capability (Brief §3, mirrors the legend in
/// `docs/device-capabilities.md`). This axis is about the PHYSICAL device only —
/// never about this Mac. A working Mac-side mechanism does NOT move this axis.
enum CapabilityStatus: String, Sendable, CaseIterable {
    case observed    = "OBSERVED"     // confirmed on the physical EP-40 with a trace
    case documented  = "DOCUMENTED"   // stated in TE docs, unverified on this unit
    case notObserved = "NOT-OBSERVED" // tested, did not occur
    case unknown     = "UNKNOWN"      // not yet tested

    /// ONLY an observed capability may unlock a device-touching feature (Brief §3).
    var unlocksFeature: Bool { self == .observed }
}

/// How far halo's OWN mechanism is built — orthogonal to device truth. A mechanism
/// can be BUILT + unit-tested on this Mac while the device fact is still UNKNOWN.
/// This axis is NEVER rendered green: a built mechanism is not a device confirmation.
enum CapabilityReadiness: String, Sendable {
    case built   = "BUILT"    // implemented + unit-tested (verified vs this Mac)
    case partial = "PARTIAL"  // scaffold / interface present, producer absent
    case absent  = "ABSENT"   // not started — device-gated (Phase 0B)
}

/// The four capability groupings surfaced in the diagnostics matrix.
enum CapabilityDomain: String, CaseIterable, Identifiable, Sendable {
    case audio           = "AUDIO"
    case midi            = "MIDI"
    case protocolStorage = "PROTOCOL / STORAGE"
    case firmware        = "FIRMWARE"

    var id: String { rawValue }
}

/// One row of the capability matrix. A pure value type: no live handles, trivially
/// `Sendable` and unit-testable. The `status`/`readiness`/`evidence`/`note` mirror a
/// row in `docs/device-capabilities.md` (that doc is canonical; this is its mirror).
struct Capability: Sendable, Identifiable, Equatable {
    let id: String            // stable slug e.g. "audio.input"
    let domain: CapabilityDomain
    let title: String
    let status: CapabilityStatus
    let readiness: CapabilityReadiness
    let evidence: String      // "Brief §3" | "DD-016" | "DD-017" | "Phase 0A" | "research/02" | …
    let note: String?         // one-line honest caveat / gate
}

enum DeviceCapabilities {

    /// Seeded catalogue mirroring `docs/device-capabilities.md` (the canonical
    /// evidence log). Static until a with-device session updates BOTH the doc and
    /// this list together.
    ///
    /// **INVARIANT (Brief §1/§4 honesty):** nothing here is `.observed` — the EP-40
    /// has never connected in a halo session. Flipping any row to `.observed` without
    /// a real device session + a matching doc update is an automatic review failure.
    /// `DeviceCapabilitiesTests` pins this.
    static let catalogue: [Capability] = [
        // MARK: AUDIO
        Capability(id: "audio.input", domain: .audio,
                   title: "USB audio input (stereo)",
                   status: .unknown, readiness: .partial,
                   evidence: "Phase 0A",
                   note: "Resolved by name (ep40AudioInput); real confirmation needs device"),
        Capability(id: "audio.output", domain: .audio,
                   title: "USB audio output",
                   status: .unknown, readiness: .built,
                   evidence: "Phase 0A",
                   note: "Enumerated on this Mac; the EP-40's own presence needs device"),
        Capability(id: "audio.enumeration", domain: .audio,
                   title: "Channels / rates / buffers + UID",
                   status: .documented, readiness: .built,
                   evidence: "DD-016",
                   note: "Verified vs this Mac's devices; the EP-40's own values need device"),
        Capability(id: "audio.monitorRoute", domain: .audio,
                   title: "Monitor route (AUHAL + ring + limiter)",
                   status: .documented, readiness: .built,
                   evidence: "DD-017",
                   note: "DSP unit-tested; the LIVE route through the EP-40 needs device"),
        Capability(id: "audio.drift", domain: .audio,
                   title: "Cross-clock drift correction",
                   status: .documented, readiness: .partial,
                   evidence: "DD-017",
                   note: "Controller built, not yet wired; needs two real clocks to tune"),
        Capability(id: "audio.recorder", domain: .audio,
                   title: "Raw pre-monitor recorder → WAV",
                   status: .documented, readiness: .built,
                   evidence: "DD-018",
                   note: "Writer / drain / metadata unit-tested; real bytes need device"),
        Capability(id: "audio.latency", domain: .audio,
                   title: "End-to-end monitor latency",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0A", note: nil),
        Capability(id: "audio.stability30m", domain: .audio,
                   title: "30-min uninterrupted monitor",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0A", note: nil),
        Capability(id: "audio.reconnect10x", domain: .audio,
                   title: "10× unplug / reconnect recovery",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0A", note: nil),

        // MARK: MIDI
        Capability(id: "midi.identity", domain: .midi,
                   title: "Identity request / reply",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0A", note: nil),
        Capability(id: "midi.padsTransmit", domain: .midi,
                   title: "Pads transmit Note On/Off",
                   status: .documented, readiness: .partial,
                   evidence: "Phase 0A",
                   note: "Mapping documented; TX direction unverified on this unit"),
        Capability(id: "midi.velocity", domain: .midi,
                   title: "Velocity present on pad notes",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0A", note: nil),
        Capability(id: "midi.noteRanges", domain: .midi,
                   title: "Note ranges 36–47=A … 72–83=D",
                   status: .documented, readiness: .built,
                   evidence: "research/02",
                   note: "Verbatim TE chart (both TX + RX columns)"),
        Capability(id: "midi.padOrder", domain: .midi,
                   title: "Internal pad order within a group",
                   status: .unknown, readiness: .partial,
                   evidence: "Phase 0A",
                   note: "ASSUMPTION only — EP40EntityNames; verify on device"),
        Capability(id: "midi.transport", domain: .midi,
                   title: "Play / Stop / Record transmit transport",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0A", note: nil),
        Capability(id: "midi.recordState", domain: .midi,
                   title: "Hardware record state observable",
                   status: .notObserved, readiness: .absent,
                   evidence: "DD-010",
                   note: "Not observable via documented USB MIDI; button_record stays unlit"),
        Capability(id: "midi.clockSend", domain: .midi,
                   title: "MIDI clock send (24 PPQN)",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0A", note: nil),
        Capability(id: "midi.ccInputs", domain: .midi,
                   title: "CC inputs recognised (1, 12, 13, 64)",
                   status: .documented, readiness: .partial,
                   evidence: "Brief §3",
                   note: "Consumed in the display path; device TX of CC unverified"),
        Capability(id: "midi.bankSelect", domain: .midi,
                   title: "Bank Select + PC selects sounds 1–999",
                   status: .documented, readiness: .absent,
                   evidence: "Phase 0A",
                   note: "Exact scheme unverified — read-only in Phase 0A"),

        // MARK: PROTOCOL / STORAGE
        Capability(id: "proto.slots", domain: .protocolStorage,
                   title: "999 sample slots (~122 MB usable)",
                   status: .documented, readiness: .absent,
                   evidence: "Brief §3",
                   note: "Prefer device-reported values over the documented figure"),
        Capability(id: "proto.listRead", domain: .protocolStorage,
                   title: "Read-only sample listing",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0B", note: nil),
        Capability(id: "proto.download", domain: .protocolStorage,
                   title: "Download one sample (byte compare)",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0B", note: nil),
        Capability(id: "proto.upload", domain: .protocolStorage,
                   title: "Guarded upload round-trip",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0B", note: nil),
        Capability(id: "proto.padAssignRead", domain: .protocolStorage,
                   title: "Pad-assignment read",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0B", note: nil),
        Capability(id: "proto.padAssignWrite", domain: .protocolStorage,
                   title: "Pad-assignment write",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0B", note: nil),
        Capability(id: "proto.framing", domain: .protocolStorage,
                   title: "SysEx framing / device ID / checksum / ack",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0B",
                   note: "Community EP-133/1320 notes are orientation only"),
        Capability(id: "proto.transferRing", domain: .protocolStorage,
                   title: "halo-ring transfer progress",
                   status: .unknown, readiness: .partial,
                   evidence: "Phase 0B",
                   note: "UI complete (HaloRingRig); producer absent"),
        Capability(id: "proto.editDeviceSample", domain: .protocolStorage,
                   title: "Edit / replace an existing device sample",
                   status: .unknown, readiness: .partial,
                   evidence: "Phase 0B",
                   note: "Needs download + upload; Edit SEND CHANGES stays disabled"),

        // MARK: FIRMWARE
        Capability(id: "fw.osVersion", domain: .firmware,
                   title: "Reports OS ≥ 2.5 (verify 2.5.1)",
                   status: .unknown, readiness: .absent,
                   evidence: "Phase 0A", note: nil),
        Capability(id: "fw.projects", domain: .firmware,
                   title: "Nine user projects",
                   status: .documented, readiness: .absent,
                   evidence: "Brief §3", note: nil),
        Capability(id: "fw.mode1", domain: .firmware,
                   title: "Mode 1 (OMNI ON, POLY)",
                   status: .documented, readiness: .absent,
                   evidence: "Brief §3", note: nil),
    ]

    /// Rows in one domain, in catalogue (doc) order.
    static func rows(in domain: CapabilityDomain) -> [Capability] {
        catalogue.filter { $0.domain == domain }
    }

    /// Honest feature gate (Brief §3): a device feature is enabled only when its
    /// backing capability is `.observed`. Today every device feature is off, because
    /// no row is observed. Existing UI already disables device features on their own
    /// honest grounds — this is the single shared assertion of the same truth.
    static func isConfirmed(_ id: String) -> Bool {
        catalogue.first { $0.id == id }?.status.unlocksFeature ?? false
    }
}

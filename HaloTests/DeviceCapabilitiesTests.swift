import XCTest
@testable import Halo

/// Pins the P4-diagnostics honesty invariants (Brief §1/§3/§4, DD-024): no
/// capability is presented as OBSERVED device truth, the feature gate stays shut,
/// the catalogue is well-formed, and the exported report renders honestly.
final class DeviceCapabilitiesTests: XCTestCase {

    // MARK: - Load-bearing honesty invariant

    /// The EP-40 has never connected in a halo session, so NOTHING may be `.observed`.
    /// This may only change alongside a real with-device session that updates BOTH
    /// `docs/device-capabilities.md` and `DeviceCapabilities.catalogue` together.
    /// Flipping a row to `.observed` without that is a faked hardware state.
    func testNoCapabilityIsObserved() {
        XCTAssertTrue(DeviceCapabilities.catalogue.allSatisfy { $0.status != .observed })
    }

    // MARK: - Feature gate

    func testFeatureGateShutForEveryDeviceFeature() {
        // Every device-touching feature is off today because its capability is not
        // observed. Spot-check the ones existing UI reads.
        XCTAssertFalse(DeviceCapabilities.isConfirmed("proto.upload"))
        XCTAssertFalse(DeviceCapabilities.isConfirmed("proto.transferRing"))
        XCTAssertFalse(DeviceCapabilities.isConfirmed("proto.editDeviceSample"))
        // And no row at all is confirmed, since none is observed.
        for capability in DeviceCapabilities.catalogue {
            XCTAssertFalse(DeviceCapabilities.isConfirmed(capability.id),
                           "\(capability.id) must not be confirmed until observed")
        }
        // An unknown id is honestly not confirmed rather than a crash.
        XCTAssertFalse(DeviceCapabilities.isConfirmed("does.not.exist"))
    }

    func testOnlyObservedUnlocksFeature() {
        XCTAssertTrue(CapabilityStatus.observed.unlocksFeature)
        XCTAssertFalse(CapabilityStatus.documented.unlocksFeature)
        XCTAssertFalse(CapabilityStatus.notObserved.unlocksFeature)
        XCTAssertFalse(CapabilityStatus.unknown.unlocksFeature)
    }

    // MARK: - Catalogue well-formedness

    func testNoDuplicateIDs() {
        let ids = DeviceCapabilities.catalogue.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "capability ids must be unique")
    }

    func testEveryDomainNonEmpty() {
        for domain in CapabilityDomain.allCases {
            XCTAssertFalse(DeviceCapabilities.rows(in: domain).isEmpty,
                           "\(domain.rawValue) must have at least one row")
        }
    }

    // MARK: - Report render

    func testReportRendersHonestlyWithEmptyTrace() {
        let report = DiagnosticsReport.text(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            palette: "A · graph paper",
            mode: "PLAY",
            live: [("STATUS · DEVICE", [("ENDPOINT", "NO DEVICE")])],
            catalogue: DeviceCapabilities.catalogue,
            frames: [])

        // Contains each domain header.
        for domain in CapabilityDomain.allCases {
            XCTAssertTrue(report.contains(domain.rawValue),
                          "report must contain the \(domain.rawValue) domain")
        }
        // Empty trace prints honestly, never a fabricated frame.
        XCTAssertTrue(report.contains("(none"))

        // No standalone OBSERVED token: every "OBSERVED" substring must be part of a
        // "NOT-OBSERVED" cell, proving nothing is presented as observed device truth.
        let observedOccurrences = report.components(separatedBy: "OBSERVED").count - 1
        let notObservedOccurrences = report.components(separatedBy: "NOT-OBSERVED").count - 1
        XCTAssertEqual(observedOccurrences, notObservedOccurrences,
                       "every OBSERVED must be inside a NOT-OBSERVED — no observed truth")
    }

    func testReportIncludesLiveBlockValues() {
        let report = DiagnosticsReport.text(
            generatedAt: Date(),
            palette: "B · bone paper",
            mode: "CAPTURE",
            live: [("STATUS · MIDI", [("CLIENT", "RUNNING")])],
            catalogue: [],
            frames: [])
        XCTAssertTrue(report.contains("STATUS · MIDI"))
        XCTAssertTrue(report.contains("CLIENT"))
        XCTAssertTrue(report.contains("RUNNING"))
        XCTAssertTrue(report.contains("CAPTURE"))
    }

    // MARK: - Protocol trace scaffold

    @MainActor
    func testProtocolTraceStartsEmptyAndRecordsThroughTheSoleSeam() {
        let trace = ProtocolTrace()
        XCTAssertTrue(trace.isEmpty)
        trace.record(.init(timestamp: Date(), direction: .tx,
                           summary: "test", bytes: [0xF0, 0x7E, 0xF7]))
        XCTAssertFalse(trace.isEmpty)
        XCTAssertEqual(trace.frames.count, 1)
        trace.clear()
        XCTAssertTrue(trace.isEmpty)
    }
}

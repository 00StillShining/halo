import XCTest
@testable import Halo

/// LOAD-mode honesty (DD-014): the session rejects a non-decodable file before
/// opening the preparation sheet (no invented metadata), and its treatment size
/// estimates are pure, `EST`-labelled functions — nothing claims a device state.
final class LoadSessionHonestyTests: XCTestCase {

    @MainActor
    func testRejectingUnreadableFileDoesNotOpenSheet() {
        let session = LoadSession()
        session.beginPreparation(
            fileURL: URL(fileURLWithPath: "/nonexistent/not-an-audio-file.wav"),
            padHint: nil)
        XCTAssertNil(session.prep, "a non-decodable file must not open the prep sheet")
    }

    func testTreatmentEstimatesAreOrderedAndPure() {
        let source = PrepMetadata(displayName: "kick.wav", durationSeconds: 1.0,
                                  sampleRate: 48000, channels: 2, bytes: 192_000)
        // ORIGINAL is the source bytes; lower-rate/mono treatments are smaller.
        XCTAssertEqual(Treatment.original.estimatedBytes(source: source), 192_000)
        XCTAssertGreaterThan(Treatment.high.estimatedBytes(source: source),
                             Treatment.balanced.estimatedBytes(source: source))
        XCTAssertGreaterThan(Treatment.balanced.estimatedBytes(source: source),
                             Treatment.lofi.estimatedBytes(source: source))
        // Pure: same input, same output.
        XCTAssertEqual(Treatment.lofi.estimatedBytes(source: source),
                       Treatment.lofi.estimatedBytes(source: source))
    }
}

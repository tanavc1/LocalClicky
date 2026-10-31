import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class StreamingPointDetectorTests: XCTestCase {
    /// Splits `text` into chunks of `size` characters and feeds the growing
    /// text, returning the index (0-based) of the chunk that fired, with the tag.
    private func firstFire(_ text: String, chunkSize: Int) -> (chunk: Int, tag: PointingTag)? {
        let detector = StreamingPointDetector()
        let characters = Array(text)
        var accumulated = ""
        var index = 0
        var position = 0
        while position < characters.count {
            let end = min(position + chunkSize, characters.count)
            accumulated += String(characters[position..<end])
            if let tag = detector.feed(accumulated: accumulated) { return (index, tag) }
            position = end
            index += 1
        }
        return nil
    }

    func testFiresExactlyOnTheChunkThatDeliversTheClosingBracket() {
        let text = "click the gear up top. [POINT:1100,42:settings gear]"
        let closingIndex = text.count - 1
        for size in [1, 2, 3, 5, 7] {
            let fire = firstFire(text, chunkSize: size)
            XCTAssertNotNil(fire, "chunk size \(size)")
            // The firing chunk is the one containing the final character.
            XCTAssertEqual(fire?.chunk, closingIndex / size, "chunk size \(size)")
            XCTAssertEqual(fire?.tag.centerInImagePixels, CGPoint(x: 1100, y: 42))
            XCTAssertEqual(fire?.tag.label, "settings gear")
        }
    }

    func testNeverFiresBeforeTheTagCloses() {
        let detector = StreamingPointDetector()
        for partial in ["click it. ", "click it. [", "click it. [POI", "click it. [POINT:11",
                        "click it. [POINT:1100,42", "click it. [POINT:1100,42:settings gea"] {
            XCTAssertNil(detector.feed(accumulated: partial), partial)
        }
        XCTAssertNotNil(detector.feed(accumulated: "click it. [POINT:1100,42:settings gear]"))
    }

    func testNoneNeverFires() {
        XCTAssertNil(firstFire("it is not on screen. [POINT:none]", chunkSize: 1))
    }

    func testFiresOnlyOncePerTurn() {
        let detector = StreamingPointDetector()
        XCTAssertNotNil(detector.feed(accumulated: "here. [POINT:10,20:a]"))
        XCTAssertNil(detector.feed(accumulated: "here. [POINT:10,20:a]"))
        XCTAssertNil(detector.feed(accumulated: "here. [POINT:10,20:a] and more"))
    }

    func testAcceptsTheLenientShapes() {
        XCTAssertEqual(firstFire("here [POINT:100,200,300,400:box]", chunkSize: 4)?.tag.centerInImagePixels,
                       CGPoint(x: 200, y: 300))
        XCTAssertEqual(firstFire(#"here [POINT x="736" y="45"]"#, chunkSize: 4)?.tag.centerInImagePixels,
                       CGPoint(x: 736, y: 45))
        XCTAssertEqual(firstFire("here [POINT:5,6:thing:screen2]", chunkSize: 4)?.tag.screenNumber, 2)
    }

    func testBareBracketFallbackDoesNotFireMidStream() {
        // The full-text parser would accept this as a point; the early detector
        // deliberately does not act on it.
        XCTAssertNil(firstFire("it is here [932,415:REC]", chunkSize: 3))
    }

    func testLaterTagAfterNoneStillFires() {
        let fire = firstFire("hmm. [POINT:none] actually. [POINT:7,8:x]", chunkSize: 5)
        XCTAssertEqual(fire?.tag.centerInImagePixels, CGPoint(x: 7, y: 8))
    }

    func testPlainTextNeverFires() {
        XCTAssertNil(firstFire("the answer is fifteen, see [1] for details.", chunkSize: 2))
    }

    // MARK: - Reconciliation

    func testReconcileAgreeingPointKeepsTheEarlyFlight() {
        XCTAssertEqual(PointReconciliation.reconcile(early: CGPoint(x: 1, y: 2), final: CGPoint(x: 1, y: 2)), .keepEarly)
    }

    func testReconcileDisagreeingPointLetsTheFinalWin() {
        XCTAssertEqual(PointReconciliation.reconcile(early: CGPoint(x: 1, y: 2), final: CGPoint(x: 9, y: 9)),
                       .dispatchFinal(CGPoint(x: 9, y: 9)))
    }

    func testReconcileWithoutEarlyDispatchesTheFinal() {
        XCTAssertEqual(PointReconciliation.reconcile(early: nil, final: CGPoint(x: 3, y: 4)),
                       .dispatchFinal(CGPoint(x: 3, y: 4)))
    }

    func testReconcileWithdrawnAndEmptyCases() {
        XCTAssertEqual(PointReconciliation.reconcile(early: CGPoint(x: 1, y: 2), final: nil), .earlyWithdrawn)
        XCTAssertEqual(PointReconciliation.reconcile(early: nil, final: nil), .nothing)
    }
}

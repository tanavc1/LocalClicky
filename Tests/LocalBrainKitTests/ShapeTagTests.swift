import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class ShapeTagTests: XCTestCase {
    private func shape(_ tag: String) -> ShapeTag? {
        if case .shape(let shape)? = ShapeTagParser.parseTag(tag) { return shape }
        return nil
    }

    // MARK: - SHAPE

    func testLineWithLabel() {
        let parsed = shape("[SHAPE:line:10,20;300,40:the toolbar divider]")
        XCTAssertEqual(parsed?.kind, .line)
        XCTAssertEqual(parsed?.points, [CGPoint(x: 10, y: 20), CGPoint(x: 300, y: 40)])
        XCTAssertEqual(parsed?.label, "the toolbar divider")
        XCTAssertNil(parsed?.screenNumber)
    }

    func testArrowWithLabelAndScreen() {
        let parsed = shape("[SHAPE:arrow:100,100;400,250:drag this:screen2]")
        XCTAssertEqual(parsed?.kind, .arrow)
        XCTAssertEqual(parsed?.label, "drag this")
        XCTAssertEqual(parsed?.screenNumber, 2)
    }

    func testCircleCentreThenRingPoint() {
        let parsed = shape("[SHAPE:circle:500,400;560,400:save button]")
        XCTAssertEqual(parsed?.kind, .circle)
        XCTAssertEqual(parsed?.points.count, 2)
    }

    func testLabelOptionalAndScreenWithoutLabel() {
        XCTAssertNotNil(shape("[SHAPE:line:1,2;3,4]"))
        XCTAssertNil(shape("[SHAPE:line:1,2;3,4]")?.label)
        let screenOnly = shape("[SHAPE:line:1,2;3,4:screen3]")
        XCTAssertNil(screenOnly?.label)
        XCTAssertEqual(screenOnly?.screenNumber, 3)
    }

    func testCurveAndPolygonPointRange() {
        func points(_ count: Int) -> String { (0..<count).map { "\($0 * 10),\($0 * 5)" }.joined(separator: ";") }
        XCTAssertNil(shape("[SHAPE:curve:\(points(2)):x]"))
        XCTAssertEqual(shape("[SHAPE:curve:\(points(3)):x]")?.points.count, 3)
        XCTAssertEqual(shape("[SHAPE:polygon:\(points(16)):x]")?.points.count, 16)
        XCTAssertNil(shape("[SHAPE:polygon:\(points(17)):x]"))
        XCTAssertNil(shape("[SHAPE:polygon:\(points(2)):x]"))
    }

    func testLineArrowCircleNeedExactlyTwoPoints() {
        for kind in ["line", "arrow", "circle"] {
            XCTAssertNil(shape("[SHAPE:\(kind):1,2:x]"), kind)
            XCTAssertNil(shape("[SHAPE:\(kind):1,2;3,4;5,6:x]"), kind)
            XCTAssertNotNil(shape("[SHAPE:\(kind):1,2;3,4:x]"), kind)
        }
    }

    func testInvalidShapesAreRejected() {
        XCTAssertNil(shape("[SHAPE:star:1,2;3,4:x]"))                // unknown kind
        XCTAssertNil(shape("[SHAPE:line:1,2;3,abc:x]"))              // bad number
        XCTAssertNil(shape("[SHAPE:line:1,2;3:x]"))                  // lone coordinate
        XCTAssertNil(shape("[SHAPE:line:1,2,9;3,4:x]"))              // three-number point
        XCTAssertNil(shape("[SHAPE:line:1,2;;3,4:x]"))               // empty point
        XCTAssertNil(shape("[SHAPE:line]"))                          // no points
        XCTAssertNil(shape("[SHAPE::1,2;3,4]"))                      // empty kind
        XCTAssertNil(shape("[SHAPE:line:1,2;3,4:a:b]"))              // two labels
        XCTAssertNil(shape("[SHAPE:line:1,2;3,inf:x]"))              // non-finite
    }

    func testCaseInsensitiveKeywordAndKind() {
        XCTAssertEqual(shape("[shape:Arrow:1,2;3,4:x]")?.kind, .arrow)
    }

    func testDecimalsAndSpacesAreTolerated() {
        let parsed = shape("[SHAPE:line: 10.5 , 20 ; 30 , 40.25 :x]")
        XCTAssertEqual(parsed?.points, [CGPoint(x: 10.5, y: 20), CGPoint(x: 30, y: 40.25)])
    }

    // MARK: - HIGHLIGHT

    func testHighlightRectLabelScreen() {
        guard case .highlight(let highlight)? = ShapeTagParser.parseTag("[HIGHLIGHT:100,200,300,260:the form:screen2]") else {
            return XCTFail("not a highlight")
        }
        XCTAssertEqual(highlight.rect, CGRect(x: 100, y: 200, width: 200, height: 60))
        XCTAssertEqual(highlight.label, "the form")
        XCTAssertEqual(highlight.screenNumber, 2)
    }

    func testHighlightNormalisesReversedCorners() {
        guard case .highlight(let highlight)? = ShapeTagParser.parseTag("[HIGHLIGHT:300,260,100,200]") else {
            return XCTFail("not a highlight")
        }
        XCTAssertEqual(highlight.rect, CGRect(x: 100, y: 200, width: 200, height: 60))
        XCTAssertNil(highlight.label)
    }

    func testInvalidHighlightsAreRejected() {
        XCTAssertNil(ShapeTagParser.parseTag("[HIGHLIGHT:1,2,3]"))
        XCTAssertNil(ShapeTagParser.parseTag("[HIGHLIGHT:1,2,3,4,5]"))
        XCTAssertNil(ShapeTagParser.parseTag("[HIGHLIGHT:a,b,c,d]"))
        XCTAssertNil(ShapeTagParser.parseTag("[HIGHLIGHT:10,10,10,50]"))   // no width
        XCTAssertNil(ShapeTagParser.parseTag("[HIGHLIGHT]"))
    }

    func testNonTagsAreNil() {
        XCTAssertNil(ShapeTagParser.parseTag("[POINT:1,2:x]"))
        XCTAssertNil(ShapeTagParser.parseTag("SHAPE:line:1,2;3,4"))
        XCTAssertNil(ShapeTagParser.parseTag("[note]"))
    }

    // MARK: - Whole text

    func testShapesReturnedInOrderAndAllTagsStripped() {
        let text = "Here is the button. [SHAPE:circle:500,400;560,400:save] Then drag it. "
            + "[SHAPE:arrow:10,10;200,200:drag] And look here. [HIGHLIGHT:1,2,30,40:box] Over there. [POINT:70,80:target]"
        let result = ShapeTagParser.parse(from: text)
        XCTAssertEqual(result.shapes.map(\.kind), [.circle, .arrow])
        XCTAssertEqual(result.highlights.count, 1)
        XCTAssertEqual(result.drawings.count, 3)
        XCTAssertEqual(result.spokenText, "Here is the button. Then drag it. And look here. Over there.")
    }

    func testDrawingsKeepInterleavedOrder() {
        let result = ShapeTagParser.parse(from: "[HIGHLIGHT:1,2,30,40][SHAPE:line:1,2;3,4][HIGHLIGHT:5,6,70,80]")
        guard result.drawings.count == 3 else { return XCTFail("count \(result.drawings.count)") }
        if case .highlight = result.drawings[0], case .shape = result.drawings[1], case .highlight = result.drawings[2] {
            XCTAssertEqual(result.spokenText, "")
        } else {
            XCTFail("order lost")
        }
    }

    func testInvalidTagsAreDroppedButStillNotSpoken() {
        let result = ShapeTagParser.parse(from: "Look. [SHAPE:line:1,2:oops] [SHAPE:line:1,2;3,4:ok] Done.")
        XCTAssertEqual(result.shapes.count, 1)
        XCTAssertEqual(result.shapes.first?.label, "ok")
        XCTAssertEqual(result.spokenText, "Look. Done.")
    }

    func testTagFirstLineLeavesTheSentence() {
        let result = ShapeTagParser.parse(from: "[SHAPE:circle:1,2;3,4:x] That is the save button.")
        XCTAssertEqual(result.spokenText, "That is the save button.")
    }

    func testPlainTextAndOtherBracketsPassThrough() {
        let result = ShapeTagParser.parse(from: "See [1] for details.")
        XCTAssertTrue(result.drawings.isEmpty)
        XCTAssertEqual(result.spokenText, "See [1] for details.")
    }

    func testUnclosedTagIsNotParsedOrStripped() {
        let result = ShapeTagParser.parse(from: "Here. [SHAPE:circle:1,2;3,4")
        XCTAssertTrue(result.drawings.isEmpty)
        XCTAssertEqual(result.spokenText, "Here. [SHAPE:circle:1,2;3,4")
    }

    func testTagCannotSpanAnotherBracket() {
        let result = ShapeTagParser.parse(from: "[SHAPE:circle:1,2 [SHAPE:line:1,2;3,4:x]")
        XCTAssertEqual(result.shapes.map(\.kind), [.line])
    }

    func testNeverCrashesOnJunk() {
        for junk in ["", "[", "]", "[]", "[SHAPE]", "[SHAPE:]", "[SHAPE::::]", "[SHAPE:line:;:]",
                     "[HIGHLIGHT:,,,]", "[SHAPE:polygon:" + String(repeating: "1,1;", count: 40) + "]",
                     "[SHAPE:line:99999999999999999999999,1;2,3]"] {
            _ = ShapeTagParser.parse(from: junk)
        }
    }
}

final class StreamingShapeDetectorTests: XCTestCase {
    /// Feeds `text` in chunks of `size` characters; returns every drawing with
    /// the index of the chunk that produced it.
    private func fireLog(_ text: String, chunkSize: Int) -> [(chunk: Int, drawing: InkDrawing)] {
        let detector = StreamingShapeDetector()
        let characters = Array(text)
        var accumulated = ""
        var log: [(Int, InkDrawing)] = []
        var index = 0
        var position = 0
        while position < characters.count {
            let end = min(position + chunkSize, characters.count)
            accumulated += String(characters[position..<end])
            for drawing in detector.feed(accumulated: accumulated) { log.append((index, drawing)) }
            position = end
            index += 1
        }
        return log
    }

    func testFiresOnTheChunkThatClosesTheTag() {
        let text = "Here is the button. [SHAPE:circle:500,400;560,400:save] And more words."
        let closing = (text.range(of: "save]")!.upperBound).utf16Offset(in: text) - 1
        for size in [1, 2, 3, 5, 9] {
            let log = fireLog(text, chunkSize: size)
            XCTAssertEqual(log.count, 1, "chunk size \(size)")
            XCTAssertEqual(log.first?.chunk, closing / size, "chunk size \(size)")
        }
    }

    func testNeverFiresBeforeTheTagCloses() {
        let detector = StreamingShapeDetector()
        for partial in ["x. ", "x. [", "x. [SHA", "x. [SHAPE:circle:1,2", "x. [SHAPE:circle:1,2;3,4:sav"] {
            XCTAssertTrue(detector.feed(accumulated: partial).isEmpty, partial)
        }
        XCTAssertEqual(detector.feed(accumulated: "x. [SHAPE:circle:1,2;3,4:save]").count, 1)
    }

    func testEachTagFiresOnceInOrder() {
        let text = "[SHAPE:line:1,2;3,4:a] mid [HIGHLIGHT:1,2,30,40:b] then [SHAPE:arrow:5,6;7,8:c] end"
        let log = fireLog(text, chunkSize: 4)
        XCTAssertEqual(log.count, 3)
        guard log.count == 3 else { return }
        if case .shape(let a) = log[0].drawing, case .highlight(let b) = log[1].drawing, case .shape(let c) = log[2].drawing {
            XCTAssertEqual([a.label, b.label, c.label], ["a", "b", "c"])
        } else {
            XCTFail("wrong order or kinds")
        }
    }

    func testRepeatedFeedsAreIdempotent() {
        let detector = StreamingShapeDetector()
        let text = "ok [SHAPE:line:1,2;3,4:a]"
        XCTAssertEqual(detector.feed(accumulated: text).count, 1)
        XCTAssertTrue(detector.feed(accumulated: text).isEmpty)
        XCTAssertTrue(detector.feed(accumulated: text + " trailing").isEmpty)
        XCTAssertEqual(detector.feed(accumulated: text + " trailing [HIGHLIGHT:1,2,3,4]").count, 1)
        XCTAssertTrue(detector.feed(accumulated: text + " trailing [HIGHLIGHT:1,2,3,4]").isEmpty)
    }

    func testTwoTagsArrivingInOneChunkBothFire() {
        let detector = StreamingShapeDetector()
        let drawings = detector.feed(accumulated: "[SHAPE:line:1,2;3,4][SHAPE:arrow:5,6;7,8]")
        XCTAssertEqual(drawings.count, 2)
    }

    func testInvalidTagIsConsumedSilentlyAndDoesNotBlockLaterOnes() {
        let detector = StreamingShapeDetector()
        XCTAssertTrue(detector.feed(accumulated: "[SHAPE:line:1,2:bad]").isEmpty)
        XCTAssertEqual(detector.feed(accumulated: "[SHAPE:line:1,2:bad] [SHAPE:line:1,2;3,4:good]").count, 1)
    }

    func testPointTagsAndPlainTextNeverFire() {
        XCTAssertTrue(fireLog("here. [POINT:10,20:x] and see [1] for more.", chunkSize: 2).isEmpty)
    }
}

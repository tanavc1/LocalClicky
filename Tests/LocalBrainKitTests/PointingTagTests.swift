import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class PointingTagTests: XCTestCase {
    func testClassicPointTag() {
        let tag = PointingTagParser.parse(from: "you'll want the color inspector. [POINT:1100,42:color inspector]")
        XCTAssertEqual(tag.spokenText, "you'll want the color inspector.")
        XCTAssertEqual(tag.centerInImagePixels, CGPoint(x: 1100, y: 42))
        XCTAssertEqual(tag.label, "color inspector")
        XCTAssertNil(tag.screenNumber)
    }

    func testPointTagWithScreenNumber() {
        let tag = PointingTagParser.parse(from: "that's on your other monitor. [POINT:400,300:terminal:screen2]")
        XCTAssertEqual(tag.centerInImagePixels, CGPoint(x: 400, y: 300))
        XCTAssertEqual(tag.label, "terminal")
        XCTAssertEqual(tag.screenNumber, 2)
    }

    func testPointTagNone() {
        let tag = PointingTagParser.parse(from: "html is the skeleton of a web page. [POINT:none]")
        XCTAssertFalse(tag.hasPoint)
        XCTAssertEqual(tag.spokenText, "html is the skeleton of a web page.")
        XCTAssertEqual(tag.label, "none")
    }

    func testBoundingBoxInsidePointTagCollapsesToCenter() {
        // Qwen-style box inside the requested tag → center.
        let tag = PointingTagParser.parse(from: "click record. [POINT:932,415,978,436:rec]")
        XCTAssertEqual(tag.centerInImagePixels, CGPoint(x: 955, y: 425.5))
        XCTAssertEqual(tag.label, "rec")
        XCTAssertNotNil(tag.boundingBoxInImagePixels)
    }

    func testBareBracketBoxFallback() {
        // Model ignored the format and emitted its native box form.
        let tag = PointingTagParser.parse(from: "here it is [589,714,692,750:Export]")
        XCTAssertEqual(tag.centerInImagePixels?.x, 640.5)
        XCTAssertEqual(tag.centerInImagePixels?.y, 732)
        XCTAssertEqual(tag.label, "Export")
        XCTAssertEqual(tag.spokenText, "here it is")
    }

    func testNoTagReturnsWholeText() {
        let tag = PointingTagParser.parse(from: "just a normal answer with no pointing")
        XCTAssertFalse(tag.hasPoint)
        XCTAssertEqual(tag.spokenText, "just a normal answer with no pointing")
        XCTAssertNil(tag.label)
    }

    func testStripsMultiplePointTags() {
        let tag = PointingTagParser.parse(from: "look here [POINT:10,20:a] and the final [POINT:30,40:b]")
        // Last tag wins for the coordinate; both tags are stripped from speech.
        XCTAssertEqual(tag.centerInImagePixels, CGPoint(x: 30, y: 40))
        XCTAssertFalse(tag.spokenText.contains("POINT"))
    }
}

import XCTest
@testable import LocalBrainKit

final class PointingLabelTests: XCTestCase {
    func testShortLabelPassesThrough() {
        XCTAssertEqual(PointingLabel.bubbleText(from: "save button"), "save button")
    }

    func testTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(PointingLabel.bubbleText(from: "  color \n  inspector  "), "color inspector")
    }

    func testStripsWrappingQuotes() {
        XCTAssertEqual(PointingLabel.bubbleText(from: "\"settings gear\""), "settings gear")
    }

    func testMissingOrEmptyKeepsRandomPhrase() {
        XCTAssertNil(PointingLabel.bubbleText(from: nil))
        XCTAssertNil(PointingLabel.bubbleText(from: ""))
        XCTAssertNil(PointingLabel.bubbleText(from: "   "))
    }

    func testPlaceholdersAreIgnored() {
        XCTAssertNil(PointingLabel.bubbleText(from: "none"))
        XCTAssertNil(PointingLabel.bubbleText(from: "Element"))
    }

    func testTooLongKeepsRandomPhrase() {
        XCTAssertNil(PointingLabel.bubbleText(from: "the small gear shaped settings control"))
        XCTAssertNil(PointingLabel.bubbleText(from: String(repeating: "a", count: PointingLabel.maxCharacters + 1)))
        XCTAssertNotNil(PointingLabel.bubbleText(from: "one two three four"))
    }
}

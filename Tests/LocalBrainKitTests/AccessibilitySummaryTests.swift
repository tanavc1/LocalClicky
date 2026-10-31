import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class AccessibilitySummaryTests: XCTestCase {
    private func record(_ role: String, title: String? = nil, value: String? = nil, description: String? = nil,
                        url: String? = nil, subrole: String? = nil, secure: Bool = false,
                        x: CGFloat = 0, y: CGFloat = 0) -> AccessibilityElementRecord {
        AccessibilityElementRecord(role: role, subrole: subrole, title: title, value: value, description: description,
                                   url: url, isSecure: secure, frame: CGRect(x: x, y: y, width: 80, height: 20))
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
    }

    func testEmptyInputGivesEmptyText() {
        XCTAssertEqual(AccessibilitySummary.summarize([]), "")
    }

    func testPlainWordsForRoles() {
        let text = AccessibilitySummary.summarize([
            record("AXButton", title: "Save", y: 10),
            record("AXLink", title: "Docs", url: "https://example.com/docs", y: 40),
            record("AXTextField", title: "Name", value: "Ada", y: 70),
            record("AXPopUpButton", title: "Format", y: 100),
        ])
        XCTAssertTrue(text.contains("- button \"Save\""))
        XCTAssertTrue(text.contains("- link \"Docs\", link to https://example.com/docs"))
        XCTAssertTrue(text.contains("- text field \"Name\", value \"Ada\""))
        XCTAssertTrue(text.contains("- pop-up menu \"Format\""))
        XCTAssertFalse(text.contains("AX"))
    }

    func testUnknownRoleFallsBackToSplitCamelCase() {
        let text = AccessibilitySummary.summarize([record("AXLayoutArea", title: "Canvas")])
        XCTAssertTrue(text.contains("- layout area \"Canvas\""))
    }

    func testSubroleWinsWhenKnown() {
        let text = AccessibilitySummary.summarize([record("AXTextField", title: "Search", subrole: "AXSearchField")])
        XCTAssertTrue(text.contains("- search field \"Search\""))
    }

    func testSecureFieldsAreDroppedEntirely() {
        let text = AccessibilitySummary.summarize([
            record("AXTextField", title: "Password", value: "hunter2", secure: true, y: 10),
            record("AXSecureTextField", title: "Pin", value: "4321", y: 40),
            record("AXTextField", title: "Pin2", value: "5555", subrole: "AXSecureTextField", y: 70),
            record("AXButton", title: "Sign in", y: 100),
        ])
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("4321"))
        XCTAssertFalse(text.contains("5555"))
        XCTAssertFalse(text.contains("Password"))
        XCTAssertFalse(text.contains("Pin"))
        XCTAssertTrue(text.contains("button \"Sign in\""))
        XCTAssertEqual(lines(text).count, 2)
    }

    func testOnlySecureFieldsGivesEmptyText() {
        XCTAssertEqual(AccessibilitySummary.summarize([record("AXTextField", title: "Password", value: "x", secure: true)]), "")
    }

    func testDuplicatesAreRemoved() {
        let text = AccessibilitySummary.summarize([
            record("AXButton", title: "Save", x: 10, y: 10),
            record("AXButton", title: "Save", x: 300, y: 200),
            record("AXButton", title: "Save as", x: 400, y: 200),
        ])
        XCTAssertEqual(lines(text).filter { $0.contains("\"Save\"") }.count, 1)
        XCTAssertEqual(lines(text).count, 3)
    }

    func testElementsWithNothingToSayAreDropped() {
        let text = AccessibilitySummary.summarize([record("AXGroup"), record("AXButton", title: "   "), record("AXButton", title: "OK")])
        XCTAssertEqual(lines(text).count, 2)
        XCTAssertTrue(text.contains("button \"OK\""))
    }

    func testReadingOrderIsTopToBottomThenLeftToRight() {
        let text = AccessibilitySummary.summarize([
            record("AXButton", title: "D", x: 200, y: 100),
            record("AXButton", title: "C", x: 10, y: 100),
            record("AXButton", title: "B", x: 200, y: 12),   // a few points lower than A, same row
            record("AXButton", title: "A", x: 10, y: 10),
        ])
        let order = lines(text).dropFirst().map { $0.split(separator: "\"")[1] }
        XCTAssertEqual(order.map(String.init), ["A", "B", "C", "D"])
    }

    func testCapsAtTwentyFiveWithACountOfTheRest() {
        let records = (0..<40).map { record("AXButton", title: "Item \($0)", y: CGFloat($0) * 30) }
        let text = AccessibilitySummary.summarize(records)
        let bullets = lines(text).filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets.count, 25)
        XCTAssertTrue(bullets.first?.contains("Item 0") == true)
        XCTAssertTrue(bullets.last?.contains("Item 24") == true)
        XCTAssertTrue(text.hasSuffix("(15 more not listed)"))
    }

    func testValuesAreTruncatedToOneTwentyCharacters() {
        let long = String(repeating: "a", count: 200)
        let text = AccessibilitySummary.summarize([record("AXTextArea", title: "Notes", value: long)])
        let valueLine = lines(text).last ?? ""
        let value = valueLine.components(separatedBy: "value \"").last?.dropLast() ?? ""
        XCTAssertEqual(value.count, 120)
        XCTAssertTrue(value.hasSuffix("..."))
    }

    func testTruncationIsTrimmedBeforeTheEllipsis() {
        let text = AccessibilitySummary.summarize([record("AXStaticText", title: "Note",
                                                          value: String(repeating: "a", count: 116) + " tail words")])
        XCTAssertTrue(text.contains("aaaa...\""), text)
        XCTAssertFalse(text.contains(" ...\""), text)
    }

    func testLinkWithNoAddressNamesWhatItSitsInside() {
        let linked = AccessibilityElementRecord(role: "AXLink", title: "Read more", linkedFrom: "group \"Blog posts\"",
                                                frame: CGRect(x: 0, y: 0, width: 80, height: 20))
        let text = AccessibilitySummary.summarize([linked])
        XCTAssertTrue(text.contains("- link \"Read more\", link with no address of its own, inside group \"Blog posts\""), text)
    }

    func testAddressWinsOverLinkedFrom() {
        let linked = AccessibilityElementRecord(role: "AXLink", title: "Docs", url: "https://example.com",
                                                linkedFrom: "group \"X\"", frame: CGRect(x: 0, y: 0, width: 80, height: 20))
        let text = AccessibilitySummary.summarize([linked])
        XCTAssertTrue(text.contains("link to https://example.com"))
        XCTAssertFalse(text.contains("no address of its own"))
    }

    func testUsableCountIgnoresSecureEmptyAndDuplicates() {
        XCTAssertEqual(AccessibilitySummary.usableCount([]), 0)
        XCTAssertEqual(AccessibilitySummary.usableCount([
            record("AXButton", title: "Save"),
            record("AXButton", title: "Save"),
            record("AXGroup"),
            record("AXTextField", title: "Password", secure: true),
            record("AXButton", title: "Cancel"),
        ]), 2)
    }

    func testShortValuesAreNotAltered() {
        let text = AccessibilitySummary.summarize([record("AXTextField", title: "Name", value: "Ada Lovelace")])
        XCTAssertTrue(text.contains("value \"Ada Lovelace\""))
    }

    func testWhitespaceAndNewlinesAreCollapsed() {
        let text = AccessibilitySummary.summarize([record("AXStaticText", value: "line one\n\n   line   two")])
        XCTAssertTrue(text.contains("value \"line one line two\""))
    }

    func testDescriptionLabelsAnElementWithoutATitle() {
        let text = AccessibilitySummary.summarize([record("AXButton", description: "Close tab")])
        XCTAssertTrue(text.contains("- button \"Close tab\""))
    }

    func testValueEqualToLabelIsNotRepeated() {
        let text = AccessibilitySummary.summarize([record("AXStaticText", title: "Total", value: "Total")])
        XCTAssertFalse(text.contains("value"))
    }

    func testIsDeterministic() {
        let records = (0..<10).map { record("AXButton", title: "B\($0)", x: CGFloat($0 % 3) * 50, y: CGFloat($0 / 3) * 40) }
        XCTAssertEqual(AccessibilitySummary.summarize(records), AccessibilitySummary.summarize(records))
    }
}

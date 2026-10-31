import CryptoKit
import XCTest
@testable import LocalBrainKit

final class PointingTargetTests: XCTestCase {
    private func context(vision: Bool = true) -> ConversationRouter.Context {
        ConversationRouter.Context(visionModeSelected: vision, screenAvailable: true,
                                   previousTurnUsedScreen: false, hasConversationHistory: false)
    }

    func testWindowAndAppRequestsNameAWindow() {
        for words in ["point out where the chat window is", "point at the claude app", "where is the mail window",
                      "show me the chat app", "which window is the chat", "point to the terminal window",
                      "Point out where the Chat window is."] {
            XCTAssertTrue(PointingTarget.namesWindow(words), words)
        }
    }

    func testTheArticleIsOptional() {
        for words in ["point out chat window", "point out claude window", "Point out where claude window is", "show me chat app",
                      "find out where the chat window is here", "point to terminal window"] {
            XCTAssertTrue(PointingTarget.namesWindow(words), words)
        }
    }

    // "the chat window bar" is the bar, a control, and not the window.
    func testBarBoxInputComposerAndSidebarAreControls() {
        for words in ["point out chat window bar to me", "Point out the chat window bar to me", "point at the message box in the chat window",
                      "where is the input in the chat window", "point to the composer in the claude app", "where is the sidebar of the notes app",
                      "point to the search bar in this app", "where is the text field in this window", "point out the chat window bars",
                      "point at the menu bar of the notes app"] {
            XCTAssertFalse(PointingTarget.namesWindow(words), words)
        }
    }

    // "title bar" is a window cue, not a control noun: the window gets the window line and the window snap.
    func testTheTitleBarNamesAWindowAndTheMenuBarStaysAControl() {
        for words in ["point at the title bar of the chat window", "point at the title bar", "where is the titlebar of the notes app",
                      "point to the title bar in the claude window"] {
            XCTAssertTrue(PointingTarget.namesWindow(words), words)
        }
        for words in ["point at the menu bar", "point at the title bar button", "point at the search bar in the title bar of the chat window"] {
            XCTAssertFalse(PointingTarget.namesWindow(words), words)
        }
    }

    func testControlRequestsDoNotNameAWindow() {
        for words in ["where is the save button in this app", "where is the settings button", "point at the search bar",
                      "click the app store icon", "where do i click to save", "which tab is the chat window in",
                      "where is the menu in the notes app", "click the music app in the dock"] {
            XCTAssertFalse(PointingTarget.namesWindow(words), words)
        }
    }

    func testTheLineRidesOnPointingClickAndPointThenDrawTurnsOnly() {
        let words = "show me where the chat window is"
        XCTAssertTrue(PointingTarget.wantsWindowLine(transcript: words, wantsPointing: true, pointDrawKind: nil))
        XCTAssertTrue(PointingTarget.wantsWindowLine(transcript: words, wantsPointing: false, pointDrawKind: .circle))
        XCTAssertFalse(PointingTarget.wantsWindowLine(transcript: words, wantsPointing: false, pointDrawKind: nil))
        XCTAssertFalse(PointingTarget.wantsWindowLine(transcript: "where is the save button", wantsPointing: true, pointDrawKind: nil))
    }

    // With drawing on, "show me where" is a draw turn drawn from a point, so it sends the point prompt
    // and has to carry the window line too.
    func testShowMeWhereTheChatWindowIsWithDrawingOnIsAPointThenDrawTurnThatGetsTheLine() {
        let words = "show me where the chat window is"
        XCTAssertEqual(DrawingRouting.route(transcript: words, context: context(), hasUsableInk: false, drawingEnabled: true),
                       .screenDraw)
        let kind = DrawingIntent.pointThenDrawKind(words, pointThenDrawEnabled: true)
        XCTAssertEqual(kind, .circle)
        XCTAssertTrue(PointingTarget.wantsWindowLine(transcript: words, wantsPointing: false, pointDrawKind: kind))
    }

    func testWordsWithoutAWindowOrAppAreNotAWindow() {
        for words in ["point at the chat", "what does this mean", "where is the windowsill", "where is the happy hour"] {
            XCTAssertFalse(PointingTarget.namesWindow(words), words)
        }
    }

    // The route the line rides on: vision mode points, text-only mode never reaches the screen.
    func testPointOutWhereTheChatWindowIsRoutesToPointing() {
        let words = "point out where the chat window is"
        XCTAssertEqual(ConversationRouter.route(transcript: words, context: context()), .screenPoint)
        XCTAssertEqual(ConversationRouter.route(transcript: words, context: context(vision: false)), .text)
        XCTAssertEqual(DrawingRouting.route(transcript: words, context: context(), hasUsableInk: false, drawingEnabled: true),
                       .screenPoint)
    }

    func testWindowTargetLineHasNoDashesNoBracketsAndOneLine() {
        let line = LocalPrompts.windowTargetLine
        XCTAssertFalse(line.contains("\u{2014}"))
        XCTAssertFalse(line.contains("\u{2013}"))
        XCTAssertFalse(line.contains("["))
        XCTAssertFalse(line.contains("\n"))
    }

    // The clicky-eval check (ce_check.py) pins the same string and the same sha256.
    func testWindowTargetLineIsPinned() {
        let digest = SHA256.hash(data: Data(LocalPrompts.windowTargetLine.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "3354f0a913966450c71e8ab37e231166c19ce702c2d3146660ea22799daa5845")
    }
}

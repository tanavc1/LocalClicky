import CryptoKit
import XCTest
@testable import LocalBrainKit

final class DrawingRoutingTests: XCTestCase {
    private func context(vision: Bool = true, screen: Bool = true) -> ConversationRouter.Context {
        ConversationRouter.Context(visionModeSelected: vision, screenAvailable: screen,
                                   previousTurnUsedScreen: false, hasConversationHistory: false)
    }

    private func route(_ words: String, enabled: Bool = true, ink: Bool = false,
                       vision: Bool = true, screen: Bool = true) -> ConversationRoute {
        DrawingRouting.route(transcript: words, context: context(vision: vision, screen: screen),
                             hasUsableInk: ink, drawingEnabled: enabled)
    }

    // MARK: - the trigger

    func testDrawingWordsTrigger() {
        for words in ["circle the save button", "can you circle that for me", "draw a circle around the error",
                      "draw an arrow to the menu", "outline this", "underline the second word",
                      "highlight the total", "highlight that line", "mark the login field",
                      "mark this one", "show me where the settings are", "draw it on my screen",
                      "draw on the screen", "circle all the links", "Highlight the Price."] {
            XCTAssertTrue(DrawingIntent.wantsDrawing(words), words)
        }
    }

    func testOrdinaryUsesOfTheWordsDoNotTrigger() {
        for words in ["what is a bookmark", "open the drawer", "i left a remark", "what is the circle of fifths",
                      "outline the steps to bake bread", "what's the highlight of the video",
                      "mark it as read", "mark this done", "how do i withdraw cash", "what is a market",
                      "draw conclusions from the data", "tell me a joke"] {
            XCTAssertFalse(DrawingIntent.wantsDrawing(words), words)
        }
    }

    // MARK: - the route

    func testEnabledDrawingWordsGoToTheDrawRoute() {
        XCTAssertEqual(route("circle the save button"), .screenDraw)
        XCTAssertEqual(route("highlight the total"), .screenDraw)
        XCTAssertEqual(route("show me where the settings are"), .screenDraw)
        XCTAssertEqual(route("draw an arrow to the menu"), .screenDraw)
    }

    func testDrawingBeatsThePointingKeywords() {
        // "highlight the" and "show me where" are pointing phrases for the
        // normal router; with drawing on they draw.
        XCTAssertEqual(InkRouting.route(transcript: "highlight the total", context: context(), hasUsableInk: false), .screenPoint)
        XCTAssertEqual(route("highlight the total"), .screenDraw)
    }

    func testDrawingTurnWithInk() {
        XCTAssertEqual(route("circle the thing i circled", ink: true), .screenDraw)
        XCTAssertEqual(route("what is this", ink: true), .screen)
    }

    func testClickWinsOverDrawing() {
        XCTAssertEqual(route("click the button i circled", ink: true), .screenClick)
        XCTAssertEqual(route("click the highlighted link"), .screenClick)
    }

    func testActionRoutesAreNeverTakenOver() {
        XCTAssertEqual(route("open spotify and mark my calendar"), InkRouting.route(
            transcript: "open spotify and mark my calendar", context: context(), hasUsableInk: false))
        XCTAssertEqual(route("set a timer for 4 minutes and mark it"), .setTimer)
    }

    func testNoScreenMeansNoDrawing() {
        XCTAssertEqual(route("circle the save button", vision: false), .text)
        XCTAssertEqual(route("circle the save button", screen: false), .text)
    }

    func testDrawingOffIsExactlyTheInkRoute() {
        let phrases = ["circle the save button", "highlight the total", "show me where the settings are",
                       "where do i click to save", "what does this button do", "what's 3 times 5",
                       "click the submit button", "point at the search bar", "open the notes app",
                       "draw a circle around the error", "mark this one", "explain this error",
                       "which button do i press to save", "what's on my screen right now",
                       "draw tic tac toe on the screen", "draw a box in the middle of the screen",
                       "draw a smiley face", "clear that drawing", "clear that"]
        for words in phrases {
            for ink in [false, true] {
                for vision in [true, false] {
                    XCTAssertEqual(route(words, enabled: false, ink: ink, vision: vision),
                                   InkRouting.route(transcript: words, context: context(vision: vision), hasUsableInk: ink),
                                   "\(words) ink=\(ink) vision=\(vision)")
                }
            }
        }
    }

    // MARK: - sketches

    func testSketchWordsGoToTheSketchRoute() {
        XCTAssertEqual(route("draw tic tac toe on the screen"), .screenSketch)
        XCTAssertEqual(route("draw a box in the middle of the screen"), .screenSketch)
        XCTAssertEqual(route("draw a smiley face"), .screenSketch)
        XCTAssertEqual(route("draw a house"), .screenSketch)
        XCTAssertEqual(route("draw a big arrow"), .screenSketch)
    }

    func testSketchWordsWithInkAreStillASketch() {
        XCTAssertEqual(route("draw tic tac toe on the screen", ink: true), .screenSketch)
        XCTAssertEqual(route("draw a smiley face", ink: true), .screenSketch)
        XCTAssertEqual(route("draw a box around the error", ink: true), .screenDraw)
        XCTAssertEqual(route("what is this", ink: true), .screen)
    }

    func testWordsThatDrawAtSomethingStayMarks() {
        XCTAssertEqual(route("draw a box around the error"), .screenDraw)
        XCTAssertEqual(route("circle the save button"), .screenDraw)
        XCTAssertEqual(route("draw an arrow to the menu"), .screenDraw)
        XCTAssertEqual(route("draw it on my screen"), .screenDraw)
    }

    func testClearWordsGoToTheClearRoute() {
        XCTAssertEqual(route("clear that drawing"), .clearMarks)
        XCTAssertEqual(route("clear that"), .clearMarks)
        XCTAssertEqual(route("clear my inbox"), InkRouting.route(transcript: "clear my inbox", context: context(), hasUsableInk: false))
        for words in ["undo that", "remove that", "get rid of that"] {
            XCTAssertEqual(route(words), InkRouting.route(transcript: words, context: context(), hasUsableInk: false), words)
            XCTAssertNotEqual(route(words), .clearMarks, words)
        }
    }

    func testClickStillWinsOverASketch() {
        XCTAssertEqual(route("click the box you drew"), .screenClick)
    }

    func testSketchAndClearAreNeverReachedWithDrawingOffOrNoScreen() {
        for words in ["draw tic tac toe on the screen", "draw a smiley face", "clear that drawing", "clear that"] {
            XCTAssertEqual(route(words, enabled: false),
                           InkRouting.route(transcript: words, context: context(), hasUsableInk: false), words)
            XCTAssertNotEqual(route(words, enabled: false), .screenSketch)
            XCTAssertNotEqual(route(words, enabled: false), .clearMarks)
            XCTAssertNotEqual(route(words, vision: false), .screenSketch)
            XCTAssertNotEqual(route(words, screen: false), .clearMarks)
        }
    }

    // MARK: - the prompt

    func testDrawPromptHasTheSizeBothTagFormsAndTheCircleRule() {
        let prompt = LocalPrompts.screenDrawResponse(imageWidthInPixels: 1152, imageHeightInPixels: 748)
        XCTAssertTrue(prompt.contains("1152x748"))
        XCTAssertTrue(prompt.contains("[SHAPE:"))
        XCTAssertTrue(prompt.contains("[HIGHLIGHT:"))
        XCTAssertTrue(prompt.contains("ex,ey is a point on the ring, directly right of the centre"))
        XCTAssertTrue(prompt.contains("just outside the thing"))
        XCTAssertTrue(prompt.contains("say what the mark is on"))
    }

    func testCircleGrammarCannotBeReadAsRadii() {
        // The 9B read `rx,ry` as radii (39 of 90 eval rows). The second pair is a
        // position on the ring, and the prompt says so in the grammar line.
        let prompt = LocalPrompts.screenDrawResponse(imageWidthInPixels: 1152, imageHeightInPixels: 748)
        XCTAssertTrue(prompt.contains("[SHAPE:circle:cx,cy;ex,ey:label]"))
        XCTAssertTrue(prompt.contains("ex,ey is a point on the ring, directly right of the centre"))
        XCTAssertTrue(prompt.contains("both pairs are positions, never sizes"))
        XCTAssertFalse(prompt.contains("rx,ry"))
    }

    func testDrawPromptsExampleParsesAndHasNoDashesOrEmoji() {
        let prompt = LocalPrompts.screenDrawResponse(imageWidthInPixels: 1152, imageHeightInPixels: 748)
        XCTAssertFalse(prompt.contains("\u{2014}"))
        XCTAssertFalse(prompt.contains("\u{2013}"))
        let example = prompt.components(separatedBy: "example:\n").last ?? ""
        let parsed = ShapeTagParser.parse(from: example)
        XCTAssertEqual(parsed.drawings.count, 2)
        XCTAssertEqual(parsed.spokenText, "that is the save button, circled.\nand this line is the error message.")
    }

    // The clicky-eval check (ce_check.py) pins the same string and the same sha256.
    func testSketchPromptIsPinnedAndHasTheFrameAndNoHighlightOrDashes() {
        let prompt = LocalPrompts.screenSketchResponse
        let digest = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "efd409d2ba83a22f80be8d88231a79025e799df4ff4125342b43d8ff802fc7c6")
        XCTAssertTrue(prompt.contains("0 to 1000"))
        XCTAssertFalse(prompt.contains("HIGHLIGHT"))
        XCTAssertFalse(prompt.contains("\u{2014}"))
        XCTAssertFalse(prompt.contains("\u{2013}"))
    }

    func testSketchPromptExampleParsesToThreePolygonsAndItsSentence() {
        let prompt = LocalPrompts.screenSketchResponse
        let example = prompt.components(separatedBy: "example, for \"draw a house\":\n").last ?? ""
        let parsed = ShapeTagParser.parse(from: example)
        XCTAssertEqual(parsed.shapes.count, 3)
        XCTAssertTrue(parsed.shapes.allSatisfy { $0.kind == .polygon })
        XCTAssertLessThanOrEqual(parsed.shapes.count, SketchLimits.maxTags)
        XCTAssertEqual(parsed.spokenText, prompt.components(separatedBy: "\n").last)
        XCTAssertEqual(parsed.spokenText, "here is a small house in the middle of your screen, with a square body, a pointed roof and a door.")
    }

    func testThePointPromptsAreUntouched() {
        // The route prompts for pointing and clicking must not mention drawing.
        XCTAssertFalse(LocalPrompts.screenPointResponse(imageWidthInPixels: 1, imageHeightInPixels: 1).contains("SHAPE"))
        XCTAssertFalse(LocalPrompts.screenClickResponse(imageWidthInPixels: 1, imageHeightInPixels: 1).contains("SHAPE"))
    }
}

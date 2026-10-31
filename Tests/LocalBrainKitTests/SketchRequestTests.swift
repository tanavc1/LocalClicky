import XCTest
@testable import LocalBrainKit

final class SketchRequestTests: XCTestCase {
    private func context(vision: Bool = true) -> ConversationRouter.Context {
        ConversationRouter.Context(visionModeSelected: vision, screenAvailable: true,
                                   previousTurnUsedScreen: false, hasConversationHistory: true)
    }

    private func route(_ words: String, drawing: Bool = true, vision: Bool = true) -> ConversationRoute {
        DrawingRouting.route(transcript: words, context: context(vision: vision), hasUsableInk: false, drawingEnabled: drawing)
    }

    private func board(_ moves: String...) -> String {
        var cells = Array(SketchTemplate.emptyBoard)
        for move in moves { cells[Int(String(move.dropFirst()))!] = move.first! }
        return String(cells)
    }

    // MARK: verbs

    func testPutPlaceMakeShowMeGiveMeAddCreateReachATemplateFigure() {
        let cases: [(String, SketchFigure)] = [
            ("put a tic tac toe on the screen", .ticTacToe),
            ("place a star on the screen", .star),
            ("make a smiley face", .smiley),
            ("make me a circle", .circle),
            ("show me a triangle", .triangle),
            ("give me an arrow", .arrow),
            ("add a box to the screen", .box),
            ("create a check mark", .check),
            ("Put a tic-tac-toe on the bottom left of my screen", .ticTacToe),
            ("can you put up a tic tac toe board", .ticTacToe),
        ]
        for (words, figure) in cases { XCTAssertEqual(SketchIntent.figure(words), figure, words) }
    }

    func testTheObjectVerbsNeverReachAFreeformFigureOrAnythingThatIsNotAFigure() {
        for words in ["make a note", "add a reminder", "put the phone down", "give me a joke", "show me the way", "create a new document",
                      "place an order", "make a house", "add two to that", "put that on my clipboard", "make sure it works",
                      "show me where the chat window is", "show me where the star is", "show me the circle of fifths",
                      "make a box around the error", "add a line to the title", "put a star next to the menu",
                      "create a new tab", "give me the time",
                      "show me the star wars trailer", "show me the box score", "give me a line from the poem",
                      "show me the arrow keys"] {
            XCTAssertNil(SketchIntent.figure(words), words)
        }
        // The draw verbs still reach freeform.
        XCTAssertEqual(SketchIntent.figure("draw a house"), .freeform("house"))
        XCTAssertEqual(SketchIntent.figure("show me how to draw a star"), .star)
    }

    // The object verbs need the whole object to be the figure: the name, a board word, placement, size, moves.
    func testTheObjectVerbsStillReachAFigureWithABoardWordPlacementSizeOrMoves() {
        XCTAssertEqual(SketchIntent.figure("put a tic tac toe on the bottom left of my screen"), .ticTacToe)
        XCTAssertEqual(SketchIntent.figure("put up a tic tac toe"), .ticTacToe)
        XCTAssertEqual(SketchIntent.figure("make a tic tac toe board"), .ticTacToe)
        XCTAssertEqual(SketchIntent.figure("give me a big tic tac toe grid in the middle"), .ticTacToe)
        XCTAssertEqual(SketchIntent.figure("put a tic tac toe with an x in the center"), .ticTacToe)
        XCTAssertEqual(SketchIntent.figure("create an empty tic tac toe board"), .ticTacToe)
        XCTAssertEqual(SketchIntent.figure("put a tic tac toe game in progress on the screen"), .ticTacToe)
        XCTAssertEqual(SketchIntent.figure("make a smiley face"), .smiley)
        XCTAssertEqual(SketchIntent.figure("add a small star in the top right corner"), .star)
        XCTAssertEqual(SketchIntent.figure("show me a check mark"), .check)
    }

    func testRoutingOfTheNewVerbsAndNothingThatWorkedBeforeChanges() {
        XCTAssertEqual(route("put a tic tac toe on the bottom left of my screen"), .screenSketch)
        XCTAssertEqual(route("make a smiley face"), .screenSketch)
        // Other routes keep their words.
        // "show me where" is a draw-from-a-point turn while drawing is on, and a pointing turn with it off.
        XCTAssertEqual(route("show me where the star is"), .screenDraw)
        XCTAssertEqual(route("show me where the save button is"), .screenDraw)
        XCTAssertEqual(route("show me where the save button is", drawing: false), .screenPoint)
        XCTAssertEqual(route("put that on my clipboard"), .copyLastAnswer)
        XCTAssertEqual(route("give me the summary in text"), .showText)
        XCTAssertEqual(route("open a new tab and go to gmail"), .browserCommand)
        XCTAssertEqual(route("launch spotify"), .openApp)
        XCTAssertEqual(route("set a timer for five minutes"), .setTimer)
        XCTAssertEqual(route("add a reminder"), .text)
        XCTAssertEqual(route("make a note"), .text)
        // Click still wins, and drawing off or no vision never sketches.
        XCTAssertNotEqual(route("click the star button"), .screenSketch)
        XCTAssertNotEqual(route("put a tic tac toe on the screen", drawing: false), .screenSketch)
        XCTAssertNotEqual(route("put a tic tac toe on the screen", vision: false), .screenSketch)
    }

    // MARK: placement and size

    func testPlacementIsParsedIntoOneOfNineRegions() {
        let cases: [(String, SketchAnchor)] = [
            ("draw a star in the top left corner", .topLeft),
            ("draw a star in the top left of the screen", .topLeft),
            ("draw a star in the upper right", .topRight),
            ("draw a star at the top", .top),
            ("draw a star on the left", .left),
            ("draw a star on the right side of my screen", .right),
            ("draw a star in the bottom left", .bottomLeft),
            ("draw a star on the bottom left of my screen", .bottomLeft),
            ("draw a star in the lower right corner", .bottomRight),
            ("draw a star at the bottom", .bottom),
            ("draw a star in the middle", .centre),
            ("draw a star in the center of the screen", .centre),
            ("draw a star in the centre", .centre),
            ("draw a star in the bottom-right corner", .bottomRight),
            ("draw a star in the top middle", .top),
            ("draw a star bottom left", .bottomLeft),
            ("draw a star", .centre),
            ("draw a star on the screen", .centre),
        ]
        for (words, anchor) in cases { XCTAssertEqual(SketchIntent.parse(words)?.anchor, anchor, words) }
    }

    func testARegionWordAloneIsNotAPlacement() {
        XCTAssertEqual(SketchIntent.parse("draw a right arrow")?.figure, .freeform("right arrow"))
        XCTAssertEqual(SketchIntent.parse("draw a right arrow")?.anchor, .centre)
    }

    func testSizeWords() {
        XCTAssertEqual(SketchIntent.parse("draw a small star")?.size, .small)
        XCTAssertEqual(SketchIntent.parse("draw a tiny star")?.size, .small)
        XCTAssertEqual(SketchIntent.parse("draw a little star")?.size, .small)
        XCTAssertEqual(SketchIntent.parse("draw a big star")?.size, .large)
        XCTAssertEqual(SketchIntent.parse("draw a huge star in the corner")?.size, .large)
        XCTAssertEqual(SketchIntent.parse("draw a star")?.size, .normal)
        XCTAssertEqual(SketchIntent.parse("draw a big arrow in the top right")?.figure, .arrow)
    }

    func testFreeformKeepsItsPhraseWithPlacementAndSizeStripped() {
        let request = SketchIntent.parse("draw a big house in the top left corner")
        XCTAssertEqual(request?.figure, .freeform("house"))
    }

    // MARK: tic tac toe board

    func testABoardIsEmptyUnlessTheWordsSayOtherwise() {
        XCTAssertEqual(SketchIntent.parse("draw tic tac toe")?.board, SketchTemplate.emptyBoard)
        XCTAssertEqual(SketchIntent.parse("draw me a tic-tac-toe grid with some xs and os")?.board, SketchTemplate.demoBoard)
        XCTAssertEqual(SketchIntent.parse("put a tic tac toe board in the bottom left")?.board, SketchTemplate.emptyBoard)
        XCTAssertEqual(SketchIntent.parse("draw a tic tac toe game in progress")?.board, SketchTemplate.demoBoard)
        XCTAssertEqual(SketchIntent.parse("draw a tic tac toe board with some moves")?.board, SketchTemplate.demoBoard)
        XCTAssertEqual(SketchIntent.parse("draw a box")?.board, SketchTemplate.emptyBoard)
    }

    func testEmptyWordsForceAnEmptyBoard() {
        for words in ["draw an empty tic tac toe board", "draw a blank tic tac toe board", "draw tic tac toe with nothing in it",
                      "draw tic tac toe with no moves", "draw tic tac toe with nothing filled in",
                      "draw an empty tic tac toe game in progress", "draw an empty tic tac toe with an x in the center"] {
            XCTAssertEqual(SketchIntent.parse(words)?.board, SketchTemplate.emptyBoard, words)
        }
    }

    func testMovesAreReadFromTheWords() {
        let cases: [(String, String)] = [
            ("draw tic tac toe with an x in the center", board("X4")),
            ("draw tic tac toe with an o in the top left", board("O0")),
            ("draw tic tac toe with x top right and o bottom left", board("X2", "O6")),
            ("draw tic tac toe with x in the middle and o in the top left corner", board("X4", "O0")),
            ("put a tic tac toe board in the bottom left with an x in the centre", board("X4")),
            ("draw tic tac toe, x in the top, o in the bottom, x on the left, o on the right", board("X1", "O7", "X3", "O5")),
            ("draw tic tac toe with an x in the center and an o in the center", board("O4")),
            ("make a tic tac toe grid with a nought in the bottom right", board("O8")),
        ]
        for (words, expected) in cases { XCTAssertEqual(SketchIntent.parse(words)?.board, expected, words) }
    }

    func testMovesNeverBecomePlacementAndPlacementNeverBecomesMoves() {
        let moveAndPlace = SketchIntent.parse("put a tic tac toe on the bottom left of my screen with an x in the center")
        XCTAssertEqual(moveAndPlace?.anchor, .bottomLeft)
        XCTAssertEqual(moveAndPlace?.board, board("X4"))
        let placeOnly = SketchIntent.parse("draw a tic tac toe board in the top left")
        XCTAssertEqual(placeOnly?.anchor, .topLeft)
        XCTAssertEqual(placeOnly?.board, SketchTemplate.emptyBoard)
        // An x with a region, but no board in the words, is a cross placed on the screen.
        let cross = SketchIntent.parse("draw an x in the center")
        XCTAssertEqual(cross?.figure, .cross)
        XCTAssertEqual(cross?.anchor, .centre)
    }

    func testMovesOnAnOnWordDoNotTripTheTargetCue() {
        // "on the top left" holds a target cue ("on the"); the move is removed before the cue check.
        XCTAssertEqual(SketchIntent.parse("draw tic tac toe with an x on the top left")?.board, board("X0"))
    }

    // The owner's real test: this was routed to chat and nothing was drawn.
    func testTheOwnersPutATicTacToeOnTheBottomLeftRequest() {
        let words = "Put a tic-tac-toe on the bottom left of my screen"
        XCTAssertEqual(route(words), .screenSketch)
        XCTAssertEqual(SketchIntent.parse(words), SketchRequest(figure: .ticTacToe, anchor: .bottomLeft, size: .normal,
                                                                 board: SketchTemplate.emptyBoard))
        let plan = SketchTemplate.plan(.ticTacToe, imageWidth: 1152, imageHeight: 720, anchor: .bottomLeft)!
        XCTAssertEqual(plan.spokenSentence, "here is an empty tic tac toe board in the bottom left of your screen.")
        XCTAssertEqual(route("Clear the TicTac"), .clearMarks)
    }

    // MARK: clear

    func testClearAcceptsFigureNamesIncludingSloppySpeechToText() {
        for words in ["clear the tictac", "clear the tic tac", "clear the tic tac toe", "Clear the TicTac", "clear the tic-tac-toe",
                      "clear the tic tac toe board", "erase tic tac toe", "clear tictactoe", "remove the tick tack toe",
                      "clear the board", "clear the grid", "clear the smiley", "erase the star", "remove the box",
                      "get rid of the arrow", "get rid of the tic tac toe", "clear the circle please", "wipe the triangle",
                      "erase that smiley face", "remove your star", "clear the check mark", "erase the cross",
                      "clear that", "erase the drawing", "clear the tic tac toe game"] {
            XCTAssertTrue(ClearMarksIntent.wants(words), words)
        }
    }

    func testClearStaysFalseForAnythingElse() {
        for words in ["clear my inbox", "clear the cache", "undo that", "remove that", "get rid of that", "clear the board meeting",
                      "clear the star from my calendar", "erase star", "remove star trek", "clear my history", "clear the table",
                      "what is a tic tac toe", "draw tic tac toe", "clear the line items", "clear all notifications"] {
            XCTAssertFalse(ClearMarksIntent.wants(words), words)
        }
    }

    func testClearRoutesFromAnyBaseRoute() {
        XCTAssertEqual(route("clear the tictac"), .clearMarks)
        XCTAssertEqual(route("erase the star"), .clearMarks)
        XCTAssertNotEqual(route("clear the tictac", drawing: false), .clearMarks)
    }

    // MARK: history note

    func testTheHistoryNoteIsNeutralAndNamesNoPositionOrMove() {
        XCTAssertEqual(SketchHistory.note(for: .ticTacToe), "(drew a tic tac toe board)")
        XCTAssertEqual(SketchHistory.note(for: .star), "(drew a star)")
        XCTAssertEqual(SketchHistory.note(for: .arrow), "(drew an arrow)")
        XCTAssertEqual(SketchHistory.note(for: .freeform("house")), "(drew a house)")
        XCTAssertEqual(SketchHistory.note(for: .freeform("owl")), "(drew an owl)")
        XCTAssertEqual(SketchHistory.note(for: .freeform("house"), drew: false), "(tried to draw a house)")
        let figures: [SketchFigure] = [.ticTacToe, .box, .line, .arrow, .circle, .triangle, .star, .smiley, .cross, .check]
        for figure in figures {
            let note = SketchHistory.note(for: figure)
            XCTAssertFalse(note.contains("here is"), note)
            XCTAssertFalse(note.contains("\u{2014}"))
        }
    }
}

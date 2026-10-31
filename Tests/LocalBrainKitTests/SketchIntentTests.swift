import XCTest
@testable import LocalBrainKit

final class SketchIntentTests: XCTestCase {
    func testSketchRequestsMapToTheirFigure() {
        let cases: [(String, SketchFigure)] = [
            ("draw tic tac toe on the screen", .ticTacToe),
            ("draw a tic tac toe board", .ticTacToe),
            ("draw me a tic-tac-toe grid with some xs and os", .ticTacToe),
            ("draw noughts and crosses", .ticTacToe),
            ("draw a box in the middle of the screen", .box),
            ("draw a big arrow", .arrow),
            ("draw a big arrow pointing up", .arrow),
            ("draw a smiley face", .smiley),
            ("sketch a star", .star),
            ("draw a triangle", .triangle),
            ("draw a circle on my screen", .circle),
            ("draw a line", .line),
            ("draw a check mark", .check),
            ("draw an x", .cross),
            ("Draw a square.", .box),
            ("draw a house", .freeform("house")),
            ("sketch a flowchart with three boxes", .freeform("flowchart with three boxes")),
            ("doodle a cat", .freeform("cat")),
            ("draw a house in the top left corner", .freeform("house")),
        ]
        for (words, figure) in cases {
            XCTAssertEqual(SketchIntent.figure(words), figure, words)
        }
    }

    func testRequestsThatDrawAtSomethingAreNotSketches() {
        for words in ["circle the save button", "draw an arrow to the menu", "draw a box around the error",
                      "draw a line under the title", "draw on this", "draw it", "draw that", "mark this one",
                      "underline the second word", "highlight the total", "draw conclusions from the data",
                      "what did you draw", "open the drawer", "withdraw cash", "open the drawing app", "can you draw",
                      "draw attention to the error", "what is the circle of fifths", "tell me a joke",
                      "draw an arrow pointing at the menu", "draw a circle around it"] {
            XCTAssertNil(SketchIntent.figure(words), words)
        }
    }

    func testClearMarksWords() {
        for words in ["clear that", "clear that drawing", "erase the drawing", "wipe the board", "remove your marks",
                      "get rid of the drawing", "undo the sketch", "can you clear the screen please", "Clear that!"] {
            XCTAssertTrue(ClearMarksIntent.wants(words), words)
        }
        for words in ["clear my inbox", "clear the cache", "delete that email", "remove the app", "clear that email",
                      "draw a box", "what is clear", "undo that", "remove that", "get rid of that",
                      "can you undo that please", "remove that email"] {
            XCTAssertFalse(ClearMarksIntent.wants(words), words)
        }
    }
}

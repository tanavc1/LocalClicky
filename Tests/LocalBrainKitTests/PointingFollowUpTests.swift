import XCTest
@testable import LocalBrainKit

final class PointingFollowUpTests: XCTestCase {
    private func context(vision: Bool = true, pointing: Bool = false) -> ConversationRouter.Context {
        ConversationRouter.Context(visionModeSelected: vision, screenAvailable: true, previousTurnUsedScreen: pointing,
                                   hasConversationHistory: true, previousTurnWasPointing: pointing)
    }

    // MARK: "where the X is" routing

    func testWhereTheObjectIsPoints() {
        for words in ["find out where the chat window is here", "Find out where the chat window is", "find where the send button is",
                      "tell me where the chat window is", "show where the settings gear is", "where the chat window is",
                      "where the send button is", "tell me where my files are", "find out where the close button is."] {
            XCTAssertTrue(ConversationRouter.wantsPointing(words.lowercased()), words)
            XCTAssertEqual(ConversationRouter.route(transcript: words, context: context()), .screenPoint, words)
            XCTAssertEqual(ConversationRouter.route(transcript: words, context: context(vision: false)), .text, words)
        }
    }

    func testWhereQuestionsAboutThePlaceOrWorldAreLeftAlone() {
        for words in ["find out where the nearest coffee shop is", "tell me where the closest pharmacy is", "where the nearby parks are",
                      "tell me where i can buy a laptop", "find where paris is", "tell me where babies come from",
                      "i wonder where the time went", "where the heck are you", "find out where the weather is nice"] {
            XCTAssertFalse(ConversationRouter.wantsPointing(words), words)
            // Vision mode and text-only mode alike: not a pointing turn.
            XCTAssertNotEqual(ConversationRouter.route(transcript: words, context: context()), .screenPoint, words)
            XCTAssertNotEqual(ConversationRouter.route(transcript: words, context: context(vision: false)), .screenPoint, words)
        }
    }

    func testTheNewPointingWordsKeepTheScreenGate() {
        let words = "find out where the chat window is"
        XCTAssertEqual(ConversationRouter.route(transcript: words, context: context(vision: false)), .text)
        let noScreen = ConversationRouter.Context(visionModeSelected: true, screenAvailable: false,
                                                  previousTurnUsedScreen: false, hasConversationHistory: false)
        XCTAssertEqual(ConversationRouter.route(transcript: words, context: noScreen), .text)
    }

    // MARK: the object of a request

    func testObjectInPointingAndClickRequests() {
        let cases: [(String, String?)] = [
            ("point out the chat window", "the chat window"),
            ("Point out chat window bar to me", "the chat window bar"),
            ("Point out the chat window bar to me", "the chat window bar"),
            ("point out where the chat window is", "the chat window"),
            ("find out where the chat window is here", "the chat window"),
            ("show me where the send button is", "the send button"),
            ("where is the save button", "the save button"),
            ("where's the settings gear?", "the settings gear"),
            ("click the submit button", "the submit button"),
            ("click on the send button please", "the send button"),
            ("point at the claude app", "the claude app"),
            ("point to my calendar", "my calendar"),
            ("highlight the total", "the total"),
            ("point out to me again", nil),
            ("point to it", nil),
            ("show me again", nil),
            ("point out that one", nil),
            ("again", nil),
            ("click it", nil),
            ("where do i click to save", nil),
        ]
        for (words, object) in cases { XCTAssertEqual(PointingFollowUp.object(in: words), object, words) }
    }

    func testFollowUpWordsAreAClosedList() {
        for words in ["point out to me again", "point to it", "point it out", "show me again", "again", "that one", "click it",
                      "point out that one", "can you point to it again", "point at it please", "one more time", "show me that one",
                      "point out to me again please"] {
            XCTAssertTrue(PointingFollowUp.isFollowUp(words), words)
        }
        for words in ["point out the chat window", "where is the save button", "what is this", "again and again and again",
                      "point out the window again", "tell me a joke", "show me where the chat window is"] {
            XCTAssertFalse(PointingFollowUp.isFollowUp(words), words)
        }
    }

    // MARK: substitution

    func testAFollowUpGetsTheLastObject() {
        let last = "the chat window"
        let again = PointingFollowUp.resolve(transcript: "Point out to me again", lastObject: last)
        XCTAssertEqual(again.transcript, "point out the chat window")
        XCTAssertEqual(again.substitutedObject, last)
        XCTAssertEqual(again.object, last)
        XCTAssertEqual(PointingFollowUp.resolve(transcript: "point to it", lastObject: last).transcript, "point out the chat window")
        XCTAssertEqual(PointingFollowUp.resolve(transcript: "show me again", lastObject: last).transcript, "point out the chat window")
        XCTAssertEqual(PointingFollowUp.resolve(transcript: "click it", lastObject: "the send button").transcript, "click the send button")
    }

    func testTheSubstitutedWordsDecideTheWindowLine() {
        let resolved = PointingFollowUp.resolve(transcript: "point out to me again", lastObject: "the chat window")
        XCTAssertFalse(PointingTarget.wantsWindowLine(transcript: "point out to me again", wantsPointing: true, pointDrawKind: nil))
        XCTAssertTrue(PointingTarget.wantsWindowLine(transcript: resolved.transcript, wantsPointing: true, pointDrawKind: nil))
        let control = PointingFollowUp.resolve(transcript: "point out to me again", lastObject: "the send button")
        XCTAssertFalse(PointingTarget.wantsWindowLine(transcript: control.transcript, wantsPointing: true, pointDrawKind: nil))
    }

    func testANewObjectReplacesTheStoredOneAndIsNeverSubstituted() {
        let resolved = PointingFollowUp.resolve(transcript: "point out the send button", lastObject: "the chat window")
        XCTAssertEqual(resolved.transcript, "point out the send button")
        XCTAssertNil(resolved.substitutedObject)
        XCTAssertEqual(resolved.object, "the send button")
        // And then a follow-up follows the new one.
        XCTAssertEqual(PointingFollowUp.resolve(transcript: "again", lastObject: resolved.object).transcript, "point out the send button")
    }

    func testNothingStoredLeavesAFollowUpAsItIs() {
        let resolved = PointingFollowUp.resolve(transcript: "point out to me again", lastObject: nil)
        XCTAssertEqual(resolved.transcript, "point out to me again")
        XCTAssertNil(resolved.substitutedObject)
        XCTAssertNil(resolved.object)
        // A turn with no object and no follow-up shape keeps what was stored.
        XCTAssertEqual(PointingFollowUp.resolve(transcript: "where do i click to save", lastObject: "the chat window").object, "the chat window")
    }

    // MARK: routing a bare follow-up

    func testBareFollowUpsPointOnlyAfterAPointingTurn() {
        for words in ["again", "that one", "show me again", "one more time"] {
            XCTAssertEqual(ConversationRouter.route(transcript: words, context: context(pointing: true)), .screenPoint, words)
            XCTAssertNotEqual(ConversationRouter.route(transcript: words, context: context(pointing: false)), .screenPoint, words)
            XCTAssertNotEqual(ConversationRouter.route(transcript: words, context: context(vision: false, pointing: true)), .screenPoint, words)
        }
        XCTAssertEqual(ConversationRouter.route(transcript: "point out to me again", context: context()), .screenPoint)
        XCTAssertEqual(ConversationRouter.route(transcript: "point to it", context: context()), .screenPoint)
        XCTAssertEqual(ConversationRouter.route(transcript: "add two to that", context: context(pointing: true)), .text)
    }

    func testTheOldFourArgumentContextStillCompiles() {
        let old = ConversationRouter.Context(visionModeSelected: true, screenAvailable: true,
                                             previousTurnUsedScreen: false, hasConversationHistory: false)
        XCTAssertFalse(old.previousTurnWasPointing)
    }
}

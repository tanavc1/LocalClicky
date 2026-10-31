import XCTest
@testable import LocalBrainKit

final class InkRoutingTests: XCTestCase {
    private func context(vision: Bool = true, screen: Bool = true,
                         previousScreen: Bool = false, history: Bool = false) -> ConversationRouter.Context {
        ConversationRouter.Context(visionModeSelected: vision, screenAvailable: screen,
                                   previousTurnUsedScreen: previousScreen, hasConversationHistory: history)
    }

    private func route(_ text: String, ink: Bool, _ context: ConversationRouter.Context? = nil) -> ConversationRoute {
        InkRouting.route(transcript: text, context: context ?? self.context(), hasUsableInk: ink)
    }

    func testNoInkLeavesTheRouterAlone() {
        for text in ["what is this", "open youtube", "click the save button", "what is two plus two", "where do i click"] {
            XCTAssertEqual(route(text, ink: false),
                           ConversationRouter.route(transcript: text, context: context()), text)
        }
    }

    func testInkWithAQuestionIsADescribeTurn() {
        XCTAssertEqual(route("what is this", ink: true), .screen)
        XCTAssertEqual(route("what does this error mean", ink: true), .screen)
    }

    func testInkBeatsActionKeywords() {
        XCTAssertEqual(route("open youtube", ink: true), .screen)
        XCTAssertEqual(route("copy your answer", ink: true), .screen)
        XCTAssertEqual(route("set a timer for four minutes", ink: true), .screen)
        XCTAssertEqual(route("what is two plus two", ink: true), .screen)
    }

    func testInkBeatsATextOnlyVerdict() {
        XCTAssertEqual(ConversationRouter.route(transcript: "what is two plus two", context: context()), .text)
        XCTAssertEqual(route("what is two plus two", ink: true), .screen)
    }

    func testPointingWordsStillPoint() {
        XCTAssertEqual(route("where do i click to save", ink: true), .screenPoint)
        XCTAssertEqual(route("point at the button i circled", ink: true), .screenPoint)
        XCTAssertEqual(route("highlight the thing i drew around", ink: true), .screenPoint)
    }

    func testClickingWordsStillClick() {
        XCTAssertEqual(route("click the button i circled", ink: true), .screenClick)
        XCTAssertEqual(route("click on that", ink: true), .screenClick)
    }

    func testWhereQuestionsStayPointingNotClicking() {
        XCTAssertEqual(route("show me where to click", ink: true), .screenPoint)
    }

    func testInkIsIgnoredWhenThereIsNoScreen() {
        let textOnly = context(vision: false, screen: true)
        XCTAssertEqual(route("what is this", ink: true, textOnly),
                       ConversationRouter.route(transcript: "what is this", context: textOnly))
        let noPermission = context(vision: true, screen: false)
        XCTAssertEqual(route("open youtube", ink: true, noPermission),
                       ConversationRouter.route(transcript: "open youtube", context: noPermission))
    }
}

import XCTest
@testable import LocalBrainKit

final class InkTurnPolicyTests: XCTestCase {
    private func plan(_ words: String, ink: Bool = true, grounding: Bool = false) -> InkTurnPlan? {
        InkTurnPolicy.plan(transcript: words, hasUsableInk: ink, wantsGrounding: grounding)
    }

    // MARK: - the classifier

    func testNamingQuestions() {
        for words in ["what is this?", "what's this right here?", "can you tell me what this is?", "What's that?",
                      "what is it", "hey clicky what's this", "what is this called", "what's this thing",
                      "what am i looking at", "name this", "which button is this", "tell me what this is",
                      "this?", "what is this one", "whats this", "What\u{2019}s this?", "okay so what is this please",
                      "what's this button", "what is this icon", "what's this thing here", "what is this option?"] {
            XCTAssertEqual(InkQuestion.kind(words), .naming, words)
        }
    }

    func testTheHarnessQuestionsName() {
        // ce_ink.py:73
        for words in ["what is this?", "what's this right here?", "can you tell me what this is?"] {
            XCTAssertEqual(InkQuestion.kind(words), .naming, words)
        }
    }

    func testOnlyFillerNames() {
        XCTAssertEqual(InkQuestion.kind(""), .naming)
        XCTAssertEqual(InkQuestion.kind("hey clicky"), .naming)
        XCTAssertEqual(InkQuestion.kind("um, ok?"), .naming)
    }

    func testEverythingElseExplains() {
        for words in ["go into detail", "go into detail about this", "what does this mean", "what is this error",
                      "what's this button for", "what is this icon doing",
                      "what's this error about", "explain this", "read this to me", "what does this say",
                      "how many lines changed here", "summarize this", "what is this doing", "what is this for",
                      "why is this red", "tell me about this", "what changed in this commit", "what is this number",
                      "translate this", "is this correct", "what is this and how many lines changed",
                      // the clicky-eval explain questions (design 4b)
                      "go into detail on what i circled", "what are the numbers here",
                      "how many lines were added and removed", "what changed here", "tell me more about this",
                      "summarize what i marked"] {
            XCTAssertEqual(InkQuestion.kind(words), .explain, words)
        }
    }

    // MARK: - the plan

    func testNoPlanWithoutInkOrOnAGroundingTurn() {
        XCTAssertNil(plan("what is this", ink: false))
        XCTAssertNil(plan("go into detail", ink: false))
        XCTAssertNil(plan("what is this", grounding: true))
        XCTAssertNil(plan("go into detail", grounding: true))
    }

    func testNamingPlanIsTheMeasuredRequest() throws {
        let naming = try XCTUnwrap(plan("what is this?"))
        XCTAssertEqual(naming.kind, .naming)
        XCTAssertEqual(naming.turnHeader, "ink-describe")
        XCTAssertFalse(naming.sendsAccessibilityBlock)
        XCTAssertFalse(naming.sendsHistory)
    }

    func testExplainPlanAnswersTheQuestion() throws {
        let explain = try XCTUnwrap(plan("go into detail"))
        XCTAssertEqual(explain.kind, .explain)
        XCTAssertEqual(explain.turnHeader, "ink-explain")
        XCTAssertTrue(explain.sendsAccessibilityBlock)
        XCTAssertTrue(explain.sendsHistory)
    }

    // MARK: - the branching CompanionManager reads

    func testHistoryRidesOnlyOnATurnThatWantsIt() throws {
        let naming = plan("what is this")
        let explain = plan("go into detail")
        XCTAssertFalse(InkTurnPolicy.sendsHistory(wantsGrounding: false, plan: naming))
        XCTAssertTrue(InkTurnPolicy.sendsHistory(wantsGrounding: false, plan: explain))
        XCTAssertTrue(InkTurnPolicy.sendsHistory(wantsGrounding: false, plan: nil))
        for plan in [naming, explain, nil] {
            XCTAssertFalse(InkTurnPolicy.sendsHistory(wantsGrounding: true, plan: plan))
        }
    }

    func testExplainTurnCarriesTheAccessibilityBlockAndTheMarkLineNamingDoesNot() throws {
        let block = "Elements inside the circled area, in reading order:\n- text \"+2,014 -4,120\""
        func userTurn(_ words: String) throws -> String {
            let plan = try XCTUnwrap(plan(words))
            return words + "\n\n" + LocalPrompts.inkAddendum(
                gestureSummary: "The user drew 1 mark while speaking: circled an area in the top left.",
                markerColourName: "yellow", hasCloseUp: true,
                accessibilityBlock: plan.sendsAccessibilityBlock ? block : "",
                markKind: .circle)
        }
        let explain = try userTurn("go into detail")
        XCTAssertTrue(explain.contains("+2,014 -4,120"))
        XCTAssertTrue(explain.hasSuffix(block + "\nthe marked thing is inside the ring."))
        let naming = try userTurn("what is this?")
        XCTAssertFalse(naming.contains("+2,014"))
        XCTAssertTrue(naming.hasSuffix("the second image is a close-up of the marked area.\nthe marked thing is inside the ring."))
    }
}

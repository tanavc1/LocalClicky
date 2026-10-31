import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class SpokenTextSegmenterTests: XCTestCase {
    func testPlainTextPassesThrough() {
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("just a normal answer"), "just a normal answer")
    }

    func testTrailingPointTagStillCutsSpeech() {
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("you'll want the toolbar. [POINT:10,20:x]"),
                       "you'll want the toolbar. ")
    }

    func testUnclosedTrailingFragmentIsHeldBack() {
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("it is here. ["), "it is here. ")
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("it is here. [SHAPE:circle:1,2;3,"), "it is here. ")
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("it is here. [POINT:1"), "it is here. ")
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("it is here. [HIGHLIGHT:1,2,3,4:lab"), "it is here. ")
    }

    func testTagFirstLineSpeaksTheSentence() {
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("[SHAPE:circle:1,2;3,4:x] That is the save button."),
                       "That is the save button.")
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("[HIGHLIGHT:1,2,30,40:form]\nThat is the form."),
                       "That is the form.")
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("[POINT:10,20:x] Here it is."), "Here it is.")
    }

    func testCompleteTagsInTheMiddleAreSkipped() {
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("Look here [SHAPE:circle:1,2;3,4:x] and then there. [POINT:5,6:y] Done."),
                       "Look here and then there. Done.")
    }

    func testTagGlueDoesNotDoubleTheSpace() {
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("One. [SHAPE:line:1,2;3,4] Two."), "One. Two.")
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("One.[SHAPE:line:1,2;3,4] Two."), "One. Two.")
    }

    func testOtherBracketsStillStopSpeech() {
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("see [1] for more"), "see ")
    }

    func testTagMatchingIsCaseInsensitive() {
        XCTAssertEqual(SpokenTextSegmenter.speakablePrefix("[shape:line:1,2;3,4] Hi."), "Hi.")
    }

    /// While streaming, the speakable prefix only ever extends what was
    /// returned before (it is what `alreadySpoken` counts into).
    func testPrefixIsStableWhileStreaming() {
        let text = "[SHAPE:circle:1,2;3,4:x] That is the button. [POINT:5,6:y] Now look. [HIGHLIGHT:1,2,30,40] End of it."
        let characters = Array(text)
        var previous = ""
        for count in 0...characters.count {
            let prefix = SpokenTextSegmenter.speakablePrefix(String(characters[0..<count]))
            XCTAssertTrue(prefix.hasPrefix(previous), "at \(count): \(prefix.debugDescription) vs \(previous.debugDescription)")
            previous = prefix
        }
        XCTAssertEqual(previous, "That is the button. Now look. End of it.")
    }

    func testSentencesStreamOutOfATagFirstAnswer() {
        let speakable = SpokenTextSegmenter.speakablePrefix("[SHAPE:circle:1,2;3,4:x] That is the save button. Click it. ")
        let first = SpokenTextSegmenter.nextCompleteSentences(speakable: speakable, alreadySpoken: 0)
        XCTAssertEqual(first?.text, "That is the save button. Click it.")
    }
}

final class PointingTagShapeStripTests: XCTestCase {
    func testSpokenTextStripsShapeAndHighlightTags() {
        let tag = PointingTagParser.parse(from: "[SHAPE:circle:1,2;3,4:x] That is it. [HIGHLIGHT:1,2,30,40:y] Look. [POINT:70,80:target]")
        XCTAssertEqual(tag.spokenText, "That is it. Look.")
        XCTAssertEqual(tag.centerInImagePixels, CGPoint(x: 70, y: 80))
        XCTAssertEqual(tag.label, "target")
    }

    func testShapeOnlyAnswerHasNoPoint() {
        let tag = PointingTagParser.parse(from: "Here. [SHAPE:arrow:1,2;3,4:go]")
        XCTAssertEqual(tag.spokenText, "Here.")
        XCTAssertFalse(tag.hasPoint)
        XCTAssertNil(tag.label)
    }

    func testInvalidShapeTagIsStillNotSpoken() {
        XCTAssertEqual(PointingTagParser.parse(from: "Here. [SHAPE:line:1,2:oops]").spokenText, "Here.")
    }

    func testPointParsingIsUnchangedByAShapeTag() {
        let withShape = PointingTagParser.parse(from: "click it [SHAPE:circle:1,2;3,4] now [POINT:932,415,978,436:rec]")
        let without = PointingTagParser.parse(from: "click it now [POINT:932,415,978,436:rec]")
        XCTAssertEqual(withShape.centerInImagePixels, without.centerInImagePixels)
        XCTAssertEqual(withShape.boundingBoxInImagePixels, without.boundingBoxInImagePixels)
        XCTAssertEqual(withShape.label, without.label)
        XCTAssertEqual(withShape.spokenText, without.spokenText)
    }
}

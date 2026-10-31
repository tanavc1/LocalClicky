import XCTest
@testable import LocalBrainKit

final class GatewayErrorSpeechTests: XCTestCase {
    func testSpeakableFieldWinsOverError() {
        let body = #"{"error":"The Studio is busy with another job. Try again later.","speakable":"custom spoken reason"}"#
        XCTAssertEqual(GatewayErrorSpeech.speakable(fromBody: body), "custom spoken reason")
    }

    func testSpeakableIsTrimmed() {
        XCTAssertEqual(GatewayErrorSpeech.speakable(fromBody: #"{"error":"x","speakable":"  hello there \n"}"#),
                       "hello there")
    }

    func testBlankSpeakableFallsBackToErrorMapping() {
        let body = #"{"error":"The Studio is busy with another job. Try again later.","speakable":"  "}"#
        XCTAssertEqual(GatewayErrorSpeech.speakable(fromBody: body),
                       "the studio is busy with another job so try again in a moment")
    }

    func testKnownErrorTextsMapWhenThereIsNoSpeakableField() {
        let cases: [(String, String)] = [
            ("The Studio connection is off. Turn it on with: clicky-gateway studio on",
             "the studio connection is off so that model is not available"),
            ("The Studio did not answer. Is oMLX running?",
             "the studio is not answering right now"),
            ("studio:dirk is not loaded on the Studio. This gateway never loads models; load it yourself.",
             "that model is not loaded on the studio"),
            ("The Studio is busy with another job. Try again later.",
             "the studio is busy with another job so try again in a moment"),
            ("Claude with screenshots needs ANTHROPIC_API_KEY set for the gateway. Text-only works without it.",
             "claude needs an api key to see the screen"),
            ("Upstream Ollama on http://127.0.0.1:11434 is not reachable",
             "the local ollama engine is not running"),
        ]
        for (errorText, expected) in cases {
            let data = try! JSONSerialization.data(withJSONObject: ["error": errorText])
            let body = String(data: data, encoding: .utf8)!
            XCTAssertEqual(GatewayErrorSpeech.speakable(fromBody: body), expected, errorText)
        }
    }

    func testUnknownErrorReturnsNilSoTheOldLineIsKept() {
        XCTAssertNil(GatewayErrorSpeech.speakable(fromBody: #"{"error":"something nobody planned for"}"#))
    }

    /// A real Ollama missing-model body must not be claimed by the mapper, or
    /// the install hint path would be lost.
    func testPlainOllamaMissingModelBodyIsNotClaimed() {
        XCTAssertNil(GatewayErrorSpeech.speakable(fromBody: #"{"error":"model 'qwen2.5vl:3b' not found"}"#))
    }

    func testNonJSONAndEmptyBodiesReturnNil() {
        XCTAssertNil(GatewayErrorSpeech.speakable(fromBody: ""))
        XCTAssertNil(GatewayErrorSpeech.speakable(fromBody: "Bad Gateway"))
        XCTAssertNil(GatewayErrorSpeech.speakable(fromBody: "[1,2,3]"))
        XCTAssertNil(GatewayErrorSpeech.speakable(fromBody: #"{"error":42}"#))
    }
}

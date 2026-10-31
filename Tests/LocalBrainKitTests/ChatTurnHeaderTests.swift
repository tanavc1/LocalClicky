import XCTest
@testable import LocalBrainKit

final class ChatTurnHeaderTests: XCTestCase {
    private func request(turn: String?) throws -> URLRequest {
        try OllamaClient.chatRequest(
            baseURL: LocalModels.defaultOllamaBaseURL, model: "studio:clicky",
            messages: [.system("s"), .user("what is this", imagesBase64: ["AAAA"])],
            temperature: 0.3, maxTokens: 320, keepAlive: "10m", contextWindow: 8192, turn: turn)
    }

    func testInkDescribeTurnCarriesTheHeader() throws {
        let request = try request(turn: OllamaClient.inkDescribeTurn)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Clicky-Turn"), "ink-describe")
    }

    func testInkExplainTurnCarriesTheHeader() throws {
        let request = try request(turn: OllamaClient.inkExplainTurn)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Clicky-Turn"), "ink-explain")
    }

    func testOtherTurnsSendNoHeader() throws {
        let request = try request(turn: nil)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Clicky-Turn"))
        XCTAssertNil(request.allHTTPHeaderFields?.keys.first { $0.lowercased() == "x-clicky-turn" })
    }

    func testTheHeaderDoesNotChangeTheBodyOrTheOtherHeaders() throws {
        let with = try request(turn: OllamaClient.inkDescribeTurn)
        let without = try request(turn: nil)
        // Dictionary key order in the serialized JSON is not stable, so compare the decoded bodies.
        let withBody = try JSONSerialization.jsonObject(with: XCTUnwrap(with.httpBody)) as? NSDictionary
        let withoutBody = try JSONSerialization.jsonObject(with: XCTUnwrap(without.httpBody)) as? NSDictionary
        XCTAssertNotNil(withBody)
        XCTAssertEqual(withBody, withoutBody)
        XCTAssertEqual(with.url, without.url)
        XCTAssertEqual(with.httpMethod, "POST")
        XCTAssertEqual(with.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
}

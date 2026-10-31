import XCTest
@testable import LocalBrainKit

final class OllamaBaseURLTests: XCTestCase {
    private let fallback = URL(string: "http://127.0.0.1:11434")!

    private func resolve(env: String? = nil, standard: String? = nil, suite: String? = nil) -> URL {
        LocalModels.resolveOllamaBaseURL(env: env, standard: standard, suite: suite)
    }

    func testFallsBackWhenNothingIsSet() {
        XCTAssertEqual(resolve(), fallback)
    }

    func testEnvBeatsStandardAndSuite() {
        let url = resolve(env: "http://127.0.0.1:1", standard: "http://127.0.0.1:2", suite: "http://127.0.0.1:3")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:1")
    }

    func testStandardBeatsSuite() {
        let url = resolve(standard: "http://127.0.0.1:2", suite: "http://127.0.0.1:3")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:2")
    }

    func testSuiteIsUsedWhenOnlySuiteIsSet() {
        XCTAssertEqual(resolve(suite: "http://localhost:3").absoluteString, "http://localhost:3")
    }

    func testIPv6LoopbackIsAccepted() {
        XCTAssertEqual(resolve(standard: "http://[::1]:11435").host, "::1")
    }

    func testNonLoopbackHostIsRejected() {
        XCTAssertEqual(resolve(env: "http://192.168.1.5:11434"), fallback)
        XCTAssertEqual(resolve(standard: "http://example.com:11434"), fallback)
        XCTAssertEqual(resolve(suite: "http://10.0.0.1:11434"), fallback)
    }

    func testNonHTTPSchemeIsRejected() {
        XCTAssertEqual(resolve(env: "https://127.0.0.1:11434"), fallback)
        XCTAssertEqual(resolve(standard: "file:///etc/hosts"), fallback)
    }

    func testGarbageIsRejected() {
        XCTAssertEqual(resolve(env: "not a url"), fallback)
        XCTAssertEqual(resolve(standard: ""), fallback)
    }

    func testInvalidHigherPrecedenceValueDoesNotFallThroughToLowerOnes() {
        // First non-nil wins, then validation: a bad env value yields the default,
        // not the (valid) suite value, matching the pre-fix behavior.
        XCTAssertEqual(resolve(env: "http://evil.example", suite: "http://127.0.0.1:3"), fallback)
    }
}

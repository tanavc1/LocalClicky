import XCTest
@testable import LocalBrainKit

final class ClickGateTests: XCTestCase {
    func testRequestThenArrivalFiresOnArrival() {
        var gate = ClickGate()
        XCTAssertFalse(gate.requestClick(), "must not click before the cursor has landed")
        XCTAssertTrue(gate.noteArrival())
    }

    func testArrivalThenRequestFiresOnRequest() {
        var gate = ClickGate()
        XCTAssertFalse(gate.noteArrival(), "arrival alone must not click")
        XCTAssertTrue(gate.requestClick())
    }

    func testTimeoutAloneDoesNotClickWithoutARequest() {
        var gate = ClickGate()
        XCTAssertFalse(gate.noteTimeout())
    }

    func testRequestThenTimeoutFiresWhenNoArrivalCanCome() {
        var gate = ClickGate()
        XCTAssertFalse(gate.requestClick())
        XCTAssertTrue(gate.noteTimeout())
    }

    func testFiresExactlyOnce() {
        var gate = ClickGate()
        XCTAssertFalse(gate.requestClick())
        XCTAssertTrue(gate.noteArrival())
        XCTAssertFalse(gate.noteArrival())
        XCTAssertFalse(gate.noteTimeout())
        XCTAssertFalse(gate.requestClick())
    }

    func testTargetChangeInvalidatesAnEarlierArrival() {
        var gate = ClickGate()
        XCTAssertFalse(gate.noteArrival())   // early flight landed
        gate.targetChanged()                 // final parse sent the cursor elsewhere
        XCTAssertFalse(gate.requestClick(), "the new target has not been reached yet")
        XCTAssertTrue(gate.noteArrival())
    }

    func testResetStartsAFreshTurn() {
        var gate = ClickGate()
        XCTAssertFalse(gate.requestClick())
        XCTAssertTrue(gate.noteArrival())
        gate.reset()
        XCTAssertFalse(gate.noteArrival(), "a previous turn's arrival must not leak into the next")
        XCTAssertTrue(gate.requestClick())
    }

    func testFallbackTimeoutExceedsTheLongestFlight() {
        XCTAssertGreaterThan(ClickGate.fallbackTimeoutSeconds, 1.4)
    }
}

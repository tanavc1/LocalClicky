import Combine
import XCTest
@testable import LocalBrainKit

/// Replays the real wiring: three @Published-style flags, combined and
/// delivered on the main queue, feeding PressCaptureLifetime. The "capture"
/// and "ink" stand in for pressCapture and pendingInkTask.
@MainActor
final class PressCaptureLifetimeTests: XCTestCase {
    private let recording = CurrentValueSubject<Bool, Never>(false)
    private let finalizing = CurrentValueSubject<Bool, Never>(false)
    private let preparing = CurrentValueSubject<Bool, Never>(false)
    private var capture: String?
    private var ink: String?
    private var lifetime: PressCaptureLifetime!
    private var cancellable: AnyCancellable?

    override func setUp() {
        super.setUp()
        lifetime = PressCaptureLifetime(
            isSettledIdle: { [unowned self] in
                !(recording.value || finalizing.value || preparing.value)
            },
            discard: { [unowned self] in
                capture = nil
                ink = nil
            }
        )
        cancellable = recording
            .combineLatest(finalizing, preparing)
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] rec, fin, prep in
                lifetime.voiceActivityEmitted(isIdle: !(rec || fin || prep))
            }
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// Key down: recording starts, capture and ink exist.
    private func pressAndHold() {
        recording.send(true)
        lifetime.beginPress()
        capture = "screenshot"
        drainMainQueue()
        ink = "ink"
    }

    /// stopPushToTalk: two separate writes, recording false then finalizing true.
    private func keyUp() {
        recording.send(false)
        finalizing.send(true)
    }

    func testCaptureAndInkSurviveKeyUpToTheClaim() {
        pressAndHold()
        keyUp()
        drainMainQueue()  // the half-written snapshot is delivered here
        XCTAssertEqual(capture, "screenshot", "capture discarded on the intermediate emission")
        XCTAssertEqual(ink, "ink", "ink discarded on the intermediate emission")
    }

    func testClaimedCaptureIsNotTouchedWhenTheSessionEnds() {
        pressAndHold()
        keyUp()
        drainMainQueue()
        let claimed = (capture, ink)
        capture = nil
        ink = nil  // sendTranscriptToLocalModel claims both
        finalizing.send(false)  // session ends right after submitDraftText
        drainMainQueue()
        XCTAssertEqual(claimed.0, "screenshot")
        XCTAssertEqual(claimed.1, "ink")
    }

    func testEmptyTranscriptStillDiscardsWhenTheSessionEnds() {
        pressAndHold()
        keyUp()
        drainMainQueue()
        finalizing.send(false)  // finished with no transcript, nothing claimed
        drainMainQueue()
        XCTAssertNil(capture)
        XCTAssertNil(ink)
    }

    func testCancelledRecordingDiscards() {
        pressAndHold()
        recording.send(false)  // cancelled before any key up
        drainMainQueue()
        XCTAssertNil(capture)
        XCTAssertNil(ink)
    }

    func testIdleFromAnEarlierSessionDoesNotDiscardANewPressCapture() {
        pressAndHold()
        keyUp()
        drainMainQueue()
        finalizing.send(false)  // session 1 ends: idle emission queued
        // Session 2's press is handled on the main queue right behind that
        // emission, before the settle check the emission schedules.
        DispatchQueue.main.async { [self] in
            lifetime.beginPress()
            capture = "second screenshot"
        }
        drainMainQueue()
        XCTAssertEqual(capture, "second screenshot")
    }
}

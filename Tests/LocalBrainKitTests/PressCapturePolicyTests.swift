import XCTest
@testable import LocalBrainKit

final class PressCapturePolicyTests: XCTestCase {
    func testCapturesOnlyInVisionModeWithScreenPermission() {
        XCTAssertTrue(PressCapturePolicy.shouldCapture(textOnlyMode: false, screenPermissionGranted: true))
        XCTAssertFalse(PressCapturePolicy.shouldCapture(textOnlyMode: true, screenPermissionGranted: true))
        XCTAssertFalse(PressCapturePolicy.shouldCapture(textOnlyMode: false, screenPermissionGranted: false))
        XCTAssertFalse(PressCapturePolicy.shouldCapture(textOnlyMode: true, screenPermissionGranted: false))
    }

    func testReusesAFreshCaptureAndRefusesAStaleOne() {
        XCTAssertTrue(PressCapturePolicy.shouldReuse(ageSeconds: 0.4))
        XCTAssertTrue(PressCapturePolicy.shouldReuse(ageSeconds: PressCapturePolicy.maxReuseAgeSeconds))
        XCTAssertFalse(PressCapturePolicy.shouldReuse(ageSeconds: PressCapturePolicy.maxReuseAgeSeconds + 0.1))
        XCTAssertFalse(PressCapturePolicy.shouldReuse(ageSeconds: -1))
    }
}

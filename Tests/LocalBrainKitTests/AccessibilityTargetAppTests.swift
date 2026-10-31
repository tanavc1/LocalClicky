import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class AccessibilityTargetAppTests: XCTestCase {
    private let own: Int32 = 100
    private func window(_ pid: Int32, _ rect: CGRect, layer: Int = 0, alpha: Double = 1) -> AccessibilityWindowInfo {
        AccessibilityWindowInfo(pid: pid, bounds: rect, layer: layer, alpha: alpha)
    }
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testOurOverlayAboveEverythingIsSkipped() {
        let windows = [window(own, screen, layer: 1000), window(200, CGRect(x: 0, y: 0, width: 500, height: 800))]
        XCTAssertEqual(AccessibilityTargetApp.owningPid(windows: windows, at: CGPoint(x: 100, y: 100), excludingPid: own), 200)
    }

    func testOurOwnNormalWindowIsSkippedToo() {
        let windows = [window(own, screen), window(300, screen)]
        XCTAssertEqual(AccessibilityTargetApp.owningPid(windows: windows, at: CGPoint(x: 10, y: 10), excludingPid: own), 300)
    }

    func testTopmostWindowAtThePointWins() {
        let windows = [window(200, CGRect(x: 0, y: 0, width: 300, height: 300)),
                       window(300, screen)]
        XCTAssertEqual(AccessibilityTargetApp.owningPid(windows: windows, at: CGPoint(x: 100, y: 100), excludingPid: own), 200)
        XCTAssertEqual(AccessibilityTargetApp.owningPid(windows: windows, at: CGPoint(x: 600, y: 600), excludingPid: own), 300)
    }

    func testMenuBarDockAndDesktopLayersAreSkipped() {
        let windows = [window(400, CGRect(x: 0, y: 0, width: 1000, height: 24), layer: 24),
                       window(401, screen, layer: 20),
                       window(402, screen, layer: -2147483623),
                       window(500, screen)]
        XCTAssertEqual(AccessibilityTargetApp.owningPid(windows: windows, at: CGPoint(x: 10, y: 10), excludingPid: own), 500)
    }

    func testInvisibleWindowIsSkipped() {
        let windows = [window(200, screen, alpha: 0), window(300, screen)]
        XCTAssertEqual(AccessibilityTargetApp.owningPid(windows: windows, at: CGPoint(x: 10, y: 10), excludingPid: own), 300)
    }

    func testNoWindowAtThePointIsNil() {
        let windows = [window(200, CGRect(x: 0, y: 0, width: 100, height: 100))]
        XCTAssertNil(AccessibilityTargetApp.owningPid(windows: windows, at: CGPoint(x: 900, y: 700), excludingPid: own))
        XCTAssertNil(AccessibilityTargetApp.owningPid(windows: [], at: .zero, excludingPid: own))
    }

    func testWindowEdgeFollowsCGRectContains() {
        let windows = [window(200, CGRect(x: 0, y: 0, width: 100, height: 100))]
        XCTAssertNil(AccessibilityTargetApp.owningPid(windows: windows, at: CGPoint(x: 100, y: 50), excludingPid: own))
        XCTAssertEqual(AccessibilityTargetApp.owningPid(windows: windows, at: CGPoint(x: 0, y: 0), excludingPid: own), 200)
    }

    func testFrontmostAppWinsWhenItIsNotUs() {
        let windows = [window(300, screen)]
        XCTAssertEqual(AccessibilityTargetApp.targetPid(frontmostPid: 250, windows: windows, at: CGPoint(x: 5, y: 5), ownPid: own), 250)
    }

    func testFrontmostIsUsFallsBackToWindowPick() {
        let windows = [window(own, screen, layer: 1000), window(300, screen)]
        XCTAssertEqual(AccessibilityTargetApp.targetPid(frontmostPid: own, windows: windows, at: CGPoint(x: 5, y: 5), ownPid: own), 300)
        XCTAssertEqual(AccessibilityTargetApp.targetPid(frontmostPid: nil, windows: windows, at: CGPoint(x: 5, y: 5), ownPid: own), 300)
    }

    func testCentreOfPoints() {
        XCTAssertNil(AccessibilityTargetApp.centre(of: []))
        let centre = AccessibilityTargetApp.centre(of: [CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 100), CGPoint(x: 30, y: 40)])
        XCTAssertEqual(centre, CGPoint(x: 30, y: 60))
    }
}

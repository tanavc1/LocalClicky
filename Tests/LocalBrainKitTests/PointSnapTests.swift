import XCTest
@testable import LocalBrainKit

final class PointSnapTests: XCTestCase {
    private func window(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ title: String? = nil, owner: String? = nil) -> SnapWindow {
        SnapWindow(title: title, owner: owner, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    // MARK: window

    func testAPointInsideAWindowGoesToThatWindowsTitleBarCentre() {
        // The model said "title bar" and gave the middle of the window.
        let snap = PointSnap.windowSnap(modelPoint: CGPoint(x: 700, y: 500),
                                        windows: [window(400, 100, 600, 700, "Claude")])
        XCTAssertEqual(snap?.point, CGPoint(x: 700, y: 114))
        XCTAssertEqual(snap?.kind, .window)
        XCTAssertEqual(snap?.matchedLabel, "Claude")
    }

    func testAMenuBarPointGoesToTheFrontmostWindowNotTheNearerBackgroundOne() {
        // y 14 is the menu bar strip. A maximized background window sits right under it (11 points away); the
        // frontmost window, first in the list, is 86 points away and wins.
        let windows = [window(400, 100, 600, 700, "Claude"), window(0, 25, 1440, 875, "Desktop Notes")]
        let snap = PointSnap.windowSnap(modelPoint: CGPoint(x: 650, y: 14), windows: windows)
        XCTAssertEqual(snap?.point, CGPoint(x: 700, y: 114))
        XCTAssertEqual(snap?.matchedLabel, "Claude")
        // The strip is the top 30 points of the display: y 29 is in it, y 31 is not and holds no window here.
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: CGPoint(x: 100, y: 29), windows: windows)?.matchedLabel, "Claude")
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: CGPoint(x: 100, y: 31), windows: windows)?.matchedLabel, "Desktop Notes")
        // On a display whose top edge is above the primary's, the strip follows that display.
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: CGPoint(x: 650, y: -460), windows: windows, displayTop: -480)?.matchedLabel, "Claude")
    }

    func testATitleOrAppNameMatchBeatsAGeometricMatch() {
        // The point is inside "Notes" (front), the request is for the chat window, which is elsewhere.
        let windows = [window(500, 300, 400, 300, "Notes"), window(1000, 100, 400, 400, "Chat")]
        let point = CGPoint(x: 600, y: 400)
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: point, object: "the chat window", windows: windows)?.matchedLabel, "Chat")
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: point, object: "the title bar of the chat window", windows: windows)?.matchedLabel, "Chat")
        // The model's own label counts when the words name no object.
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: point, object: nil, label: "chat window", windows: windows)?.matchedLabel, "Chat")
        // The owning app's name counts, with a window title that says nothing of it.
        let apps = [window(500, 300, 400, 300, "Untitled", owner: "TextEdit"), window(1000, 100, 400, 400, "Inbox", owner: "Mail")]
        let mail = PointSnap.windowSnap(modelPoint: point, object: "the mail app", windows: apps)
        XCTAssertEqual(mail?.point, CGPoint(x: 1200, y: 114))
        XCTAssertEqual(mail?.matchedLabel, "Inbox")
        // A name that matches no window falls back to the point.
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: point, object: "the zebra window", windows: windows)?.matchedLabel, "Notes")
        // The best score wins, then the frontmost.
        let twins = [window(0, 100, 300, 300, "Chat", owner: "A"), window(400, 100, 300, 300, "Chat", owner: "B")]
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: CGPoint(x: 500, y: 200), object: "chat", windows: twins)?.point.x, 150)
    }

    func testADockIconPointWithNoWindowUnderItIsLeftAlone() {
        // The model correctly pointed at the Dock icon of an app that has no window open.
        let windows = [window(400, 100, 600, 700, "Claude")]
        XCTAssertNil(PointSnap.windowSnap(modelPoint: CGPoint(x: 1200, y: 880), object: "the music app", windows: windows))
    }

    func testTheNearestWindowIsUsedOnlyWithinSixtyPoints() {
        let windows = [window(400, 100, 600, 700, "Claude")]
        // 59 points left of the window's left edge, then 61.
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: CGPoint(x: 341, y: 400), windows: windows)?.matchedLabel, "Claude")
        XCTAssertNil(PointSnap.windowSnap(modelPoint: CGPoint(x: 339, y: 400), windows: windows))
        XCTAssertEqual(PointSnap.nearestWindowRadius, 60)
    }

    func testTheTitleBarPointIsClampedBelowTheMenuBarStrip() {
        // The window's top edge is above the display: its title bar centre would be in the menu bar.
        let snap = PointSnap.windowSnap(modelPoint: CGPoint(x: 500, y: 200), windows: [window(400, -20, 600, 700, "Tall")])
        XCTAssertEqual(snap?.point.y, 30)
        let other = PointSnap.windowSnap(modelPoint: CGPoint(x: 500, y: -300), windows: [window(400, -500, 600, 700, "Above")], displayTop: -480)
        XCTAssertEqual(other?.point.y, -450)
    }

    func testTheFrontmostWindowThatHoldsThePointWins() {
        let windows = [window(500, 300, 400, 300, "Front"), window(400, 100, 700, 700, "Back")]
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: CGPoint(x: 600, y: 400), windows: windows)?.matchedLabel, "Front")
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: CGPoint(x: 450, y: 150), windows: windows)?.matchedLabel, "Back")
    }

    func testNoWindowKeepsTheModelsPointAndATinyWindowIsNotAWindow() {
        XCTAssertNil(PointSnap.windowSnap(modelPoint: CGPoint(x: 10, y: 10), windows: []))
        XCTAssertNil(PointSnap.windowSnap(modelPoint: CGPoint(x: 10, y: 10), windows: [window(0, 0, 60, 24)]))
    }

    func testTheTitleBarPointStaysInsideAShortWindow() {
        let snap = PointSnap.windowSnap(modelPoint: CGPoint(x: 150, y: 110), windows: [window(100, 100, 200, 80)])
        XCTAssertEqual(snap?.point.y ?? 0, 114, accuracy: 0.001)
    }

    // MARK: control

    private func element(_ label: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 80, _ h: CGFloat = 30) -> SnapCandidate {
        SnapCandidate(labels: [label], frame: CGRect(x: x, y: y, width: w, height: h))
    }

    func testTheElementUnderThePointIsKeptWhenItsLabelMatches() {
        let snap = PointSnap.controlSnap(modelPoint: CGPoint(x: 410, y: 212), label: "send button",
                                         candidates: [element("Send", 400, 200), element("Cancel", 500, 200)])
        XCTAssertEqual(snap.kind, .ax)
        XCTAssertEqual(snap.point, CGPoint(x: 440, y: 215))
        XCTAssertEqual(snap.matchedLabel, "Send")
    }

    func testAMismatchedHitFallsBackToTheBestMatchWithinTheRadius() {
        // The point is on "Cancel"; the label says send; "Send" is 90 points away.
        let snap = PointSnap.controlSnap(modelPoint: CGPoint(x: 540, y: 215), label: "send button",
                                         candidates: [element("Cancel", 500, 200), element("Send", 400, 200)])
        XCTAssertEqual(snap.kind, .ax)
        XCTAssertEqual(snap.matchedLabel, "Send")
        XCTAssertEqual(snap.point, CGPoint(x: 440, y: 215))
    }

    func testAMatchBeyondTheRadiusIsIgnoredAndTheModelsPointStays() {
        let model = CGPoint(x: 1000, y: 215)
        let snap = PointSnap.controlSnap(modelPoint: model, label: "send button", candidates: [element("Send", 400, 200)])
        XCTAssertEqual(snap, PointSnapResult(point: model, kind: .none, matchedLabel: nil))
        XCTAssertEqual(PointSnap.searchRadius, 120)
    }

    func testNoLabelOrNoMatchKeepsTheModelsPoint() {
        let model = CGPoint(x: 410, y: 212)
        for label in [nil, "", "the", "zebra stripes"] as [String?] {
            XCTAssertEqual(PointSnap.controlSnap(modelPoint: model, label: label, candidates: [element("Send", 400, 200)]).kind, .none)
        }
        XCTAssertEqual(PointSnap.controlSnap(modelPoint: model, label: "send", candidates: []).kind, .none)
    }

    func testTheNearestMatchWinsAmongEqualOnes() {
        let snap = PointSnap.controlSnap(modelPoint: CGPoint(x: 300, y: 215), label: "send",
                                         candidates: [element("Send", 400, 200), element("Send", 150, 200)])
        XCTAssertEqual(snap.point.x, 190, accuracy: 0.001)
    }

    func testAnEmptyFrameIsNeverSnappedTo() {
        let snap = PointSnap.controlSnap(modelPoint: CGPoint(x: 10, y: 10), label: "send",
                                         candidates: [SnapCandidate(labels: ["Send"], frame: .zero)])
        XCTAssertEqual(snap.kind, .none)
    }

    func testTheSmallestContainingMatchWinsOverALargerOne() {
        let big = SnapCandidate(labels: ["Send message"], frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let small = element("Send message", 400, 200)
        XCTAssertEqual(PointSnap.controlSnap(modelPoint: CGPoint(x: 410, y: 210), label: "send message", candidates: [big, small]).point,
                       CGPoint(x: 440, y: 215))
    }

    func testAContainerIsNeverAControlEvenWhenItsLabelScoresOne() {
        let group = SnapCandidate(labels: ["Send"], frame: CGRect(x: 400, y: 200, width: 100, height: 60), role: "AXGroup")
        XCTAssertEqual(PointSnap.labelScore("send", "Send"), 1)
        XCTAssertEqual(PointSnap.controlSnap(modelPoint: CGPoint(x: 410, y: 210), label: "send", candidates: [group]).kind, .none)
        for role in ["AXWindow", "AXSheet", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXWebArea", "AXToolbar", "AXLayoutArea", "AXApplication"] {
            let container = SnapCandidate(labels: ["Send"], frame: CGRect(x: 400, y: 200, width: 100, height: 60), role: role)
            XCTAssertEqual(PointSnap.controlSnap(modelPoint: CGPoint(x: 410, y: 210), label: "send", candidates: [container]).kind, .none, role)
        }
        // The same frame as a button is a control.
        let button = SnapCandidate(labels: ["Send"], frame: CGRect(x: 400, y: 200, width: 100, height: 60), role: "AXButton")
        XCTAssertEqual(PointSnap.controlSnap(modelPoint: CGPoint(x: 410, y: 210), label: "send", candidates: [button]).kind, .ax)
    }

    func testALargeMatchingElementWithNoSmallMatchLeavesThePointWhereItIs() {
        let model = CGPoint(x: 410, y: 210)
        let large = SnapCandidate(labels: ["Send message"], frame: CGRect(x: 0, y: 0, width: 800, height: 600), role: "AXGroup")
        XCTAssertEqual(PointSnap.controlSnap(modelPoint: model, label: "send message", candidates: [large]),
                       PointSnapResult(point: model, kind: .none, matchedLabel: nil))
        // Without a container role, the size cap alone drops it: 401 wide and 301 high are too big, 400 x 300 is not.
        for (width, height) in [(401.0, 100.0), (100.0, 301.0)] {
            let wide = SnapCandidate(labels: ["Send message"], frame: CGRect(x: 400, y: 200, width: width, height: height))
            XCTAssertEqual(PointSnap.controlSnap(modelPoint: model, label: "send message", candidates: [wide]).kind, .none)
        }
        let edge = SnapCandidate(labels: ["Send message"], frame: CGRect(x: 400, y: 200, width: 400, height: 300))
        XCTAssertEqual(PointSnap.controlSnap(modelPoint: model, label: "send message", candidates: [edge]).kind, .ax)
    }

    func testTheSmallestContainingMatchBeatsABetterScoringLargerOne() {
        let exact = SnapCandidate(labels: ["Send"], frame: CGRect(x: 400, y: 200, width: 300, height: 200), role: "AXButton")
        let partial = SnapCandidate(labels: ["Send button"], frame: CGRect(x: 405, y: 205, width: 40, height: 20), role: "AXButton")
        let snap = PointSnap.controlSnap(modelPoint: CGPoint(x: 410, y: 210), label: "send", candidates: [exact, partial])
        XCTAssertEqual(snap.matchedLabel, "Send button")
        XCTAssertEqual(snap.point, CGPoint(x: 425, y: 215))
    }

    // What the user typed is never a label: a record with only a value is not a candidate, so it cannot be
    // matched, snapped to or logged as matchedLabel, even though its text scores 1 against the model's label.
    func testATextFieldsTypedValueIsNeverACandidateLabel() {
        let frame = CGRect(x: 400, y: 200, width: 200, height: 30)
        let typed = AccessibilityElementRecord(role: "AXTextField", value: "my bank password hunter2", frame: frame)
        XCTAssertEqual(PointSnap.labelScore("my bank password hunter2", "my bank password hunter2"), 1)
        XCTAssertTrue(PointSnap.candidates(from: [typed]).isEmpty)
        XCTAssertEqual(PointSnap.controlSnap(modelPoint: CGPoint(x: 410, y: 210), label: "my bank password hunter2",
                                             candidates: PointSnap.candidates(from: [typed])).kind, .none)
        // With a title, only the title is a label; the value stays out.
        let titled = AccessibilityElementRecord(role: "AXTextField", title: "Search", value: "hunter2", description: "Search field", frame: frame)
        XCTAssertEqual(PointSnap.candidates(from: [titled]), [SnapCandidate(labels: ["Search", "Search field"], frame: frame, role: "AXTextField")])
        // Secure and frameless records are left out as before.
        XCTAssertTrue(PointSnap.candidates(from: [AccessibilityElementRecord(role: "AXSecureTextField", title: "Password", frame: frame),
                                                  AccessibilityElementRecord(role: "AXButton", title: "Send", isSecure: true, frame: frame),
                                                  AccessibilityElementRecord(role: "AXButton", title: "Send")]).isEmpty)
    }

    func testLabelMatching() {
        XCTAssertEqual(PointSnap.labelScore("Send", "send"), 1)
        XCTAssertEqual(PointSnap.labelScore("send button", "Send"), 0.5)
        XCTAssertEqual(PointSnap.labelScore("settings gear", "Settings"), 0.5)
        XCTAssertEqual(PointSnap.labelScore("setting", "Settings"), 1)
        XCTAssertEqual(PointSnap.labelScore("new tab", "New Window"), 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(PointSnap.labelScore("the send button", "send, button"), 1)
        XCTAssertEqual(PointSnap.labelScore("", "send"), 0)
        XCTAssertEqual(PointSnap.labelScore("the", "the"), 0)
        XCTAssertEqual(PointSnap.labelThreshold, 0.5)
        XCTAssertLessThan(PointSnap.labelScore("new tab", "New Window"), PointSnap.labelThreshold)
        XCTAssertLessThan(PointSnap.labelScore("send button", "send message"), PointSnap.labelThreshold)
        // Short tokens only match whole, so "tab" is not "table".
        XCTAssertEqual(PointSnap.labelScore("tab", "table"), 0)
    }

    func testProbePointsAreTheModelsPointThenTwoRings() {
        let points = PointSnap.probePoints(around: CGPoint(x: 500, y: 400))
        XCTAssertEqual(points.count, 17)
        XCTAssertEqual(points[0], CGPoint(x: 500, y: 400))
        for point in points.dropFirst().prefix(8) { XCTAssertEqual(hypot(point.x - 500, point.y - 400), 60, accuracy: 0.001) }
        for point in points.suffix(8) { XCTAssertEqual(hypot(point.x - 500, point.y - 400), 120, accuracy: 0.001) }
    }

    // MARK: coordinate spaces

    // The model's point is in screenshot pixels (the gateway rescaled norm1000). The app maps it to a Core Graphics
    // global point (top-left of the primary display, y down), the space of AX frames and window bounds, snaps
    // there, and maps the result back to pixels for the cursor. A second display above-right of a primary of
    // 1440x900 points makes the origin and the flip matter.
    func testScreenshotPixelsToCoreGraphicsPointsAndBack() {
        let primaryHeight: CGFloat = 900
        // Secondary display: 1920x1080 points, its AppKit frame bottom-left at (1440, 300): it spans AppKit y 300 to 1380.
        let mapping = ScreenMapping(displayFrame: CGRect(x: 1440, y: 300, width: 1920, height: 1080),
                                    displayWidthInPoints: 1920, displayHeightInPoints: 1080,
                                    screenshotWidthInPixels: 1152, screenshotHeightInPixels: 648)
        // Screenshot pixel (576, 324) is the display's centre: 960, 540 points into the display.
        let pixel = CGPoint(x: 576, y: 324)
        let local = mapping.displayLocalPoint(forImagePoint: pixel)
        XCTAssertEqual(local, CGPoint(x: 960, y: 540))
        let cg = mapping.cgGlobalPoint(forDisplayLocalPoint: local, primaryScreenHeight: primaryHeight)
        // x: 1440 + 960. AppKit y = 300 + (1080 - 540) = 840, CG y = 900 - 840 = 60.
        XCTAssertEqual(cg, CGPoint(x: 2400, y: 60))
        let back = mapping.imagePoint(forCGGlobalPoint: cg, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(back.x, pixel.x, accuracy: 0.001)
        XCTAssertEqual(back.y, pixel.y, accuracy: 0.001)

        // The display's top edge in CG is 900 - (300 + 1080) = -480: a point on the secondary display can have a negative y.
        let top = mapping.cgGlobalPoint(forDisplayLocalPoint: .zero, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(top, CGPoint(x: 1440, y: -480))
    }

    func testARoundTripHoldsOnThePrimaryDisplayAndForAnyPixel() {
        let mapping = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                    displayWidthInPoints: 1440, displayHeightInPoints: 900,
                                    screenshotWidthInPixels: 1152, screenshotHeightInPixels: 720)
        for pixel in [CGPoint(x: 0, y: 0), CGPoint(x: 1152, y: 720), CGPoint(x: 14, y: 14), CGPoint(x: 800, y: 123.5)] {
            let cg = mapping.cgGlobalPoint(forDisplayLocalPoint: mapping.displayLocalPoint(forImagePoint: pixel), primaryScreenHeight: 900)
            // On the primary display, CG is display-local: top-left origin, 1440 points for 1152 pixels.
            XCTAssertEqual(cg.x, pixel.x * 1.25, accuracy: 0.001)
            XCTAssertEqual(cg.y, pixel.y * 1.25, accuracy: 0.001)
            let back = mapping.imagePoint(forCGGlobalPoint: cg, primaryScreenHeight: 900)
            XCTAssertEqual(back.x, pixel.x, accuracy: 0.001)
            XCTAssertEqual(back.y, pixel.y, accuracy: 0.001)
        }
    }

    // The log's example: a window request answered with y 14 in 1152x720 pixels is the menu bar strip.
    func testAMenuBarPixelSnapsToTheWindowBelowAndComesBackAsAPixelInsideTheWindow() {
        let mapping = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                    displayWidthInPoints: 1440, displayHeightInPoints: 900,
                                    screenshotWidthInPixels: 1152, screenshotHeightInPixels: 720)
        let cg = mapping.cgGlobalPoint(forDisplayLocalPoint: mapping.displayLocalPoint(forImagePoint: CGPoint(x: 600, y: 14)),
                                       primaryScreenHeight: 900)
        XCTAssertEqual(cg.y, 17.5, accuracy: 0.001)
        let claude = SnapWindow(title: "Claude", frame: CGRect(x: 300, y: 38, width: 900, height: 800))
        let snap = PointSnap.windowSnap(modelPoint: cg, windows: [claude])!
        XCTAssertEqual(snap.point, CGPoint(x: 750, y: 52))
        let pixel = mapping.imagePoint(forCGGlobalPoint: snap.point, primaryScreenHeight: 900)
        XCTAssertEqual(pixel.x, 600, accuracy: 0.001)
        XCTAssertEqual(pixel.y, 41.6, accuracy: 0.001)
    }
}

import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class PointThenDrawTests: XCTestCase {
    // A 2560 x 1440 pt external display captured at 1152 x 648 px (0.45 px per pt).
    private let external = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                         displayWidthInPoints: 2560, displayHeightInPoints: 1440,
                                         screenshotWidthInPixels: 1152, screenshotHeightInPixels: 648)
    // A portrait display, so the most room is above or below.
    private let portrait = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 400, height: 800),
                                         displayWidthInPoints: 400, displayHeightInPoints: 800,
                                         screenshotWidthInPixels: 400, screenshotHeightInPixels: 800)

    private struct NotAShape: Error {}

    private func shape(_ plan: PointDrawPlan) throws -> ShapeTag {
        guard case .shape(let tag) = plan.drawing else {
            XCTFail("the plan must be a shape, got \(plan.drawing)")
            throw NotAShape()
        }
        return tag
    }

    // MARK: - circle

    func testCircleWithoutAFrameUsesTheDefaultRadiusDirectlyRightOfTheCentre() throws {
        let plan = PointThenDraw.plan(kind: .circle, pointInImagePixels: CGPoint(x: 400, y: 300),
                                      label: "save button", controlFrameInDisplayPoints: nil, mapping: external)
        let tag = try shape(plan)
        XCTAssertEqual(tag.kind, .circle)
        XCTAssertEqual(tag.points, [CGPoint(x: 400, y: 300),
                                    CGPoint(x: 400 + PointThenDraw.defaultRingRadiusInImagePixels, y: 300)])
        XCTAssertEqual(tag.label, "save button")
        XCTAssertEqual(PointThenDraw.defaultRingRadiusInImagePixels, 30)
    }

    func testCircleWithAFrameUsesHalfTheDiagonalTimesOnePointOneFive() throws {
        // A 96 x 28 pt control under the point: diagonal 100 pt, so r = 57.5 pt = 25.875 px.
        let frame = CGRect(x: 800, y: 600, width: 96, height: 28)
        let point = CGPoint(x: 848 * 0.45, y: 614 * 0.45)
        let tag = try shape(PointThenDraw.plan(kind: .circle, pointInImagePixels: point, label: "x",
                                               controlFrameInDisplayPoints: frame, mapping: external))
        // Centred on the frame (848, 614 pt = 381.6, 276.3 px), not on the point.
        let frameCentre = CGPoint(x: 848 * 0.45, y: 614 * 0.45)
        let offPoint = CGPoint(x: point.x + 10, y: point.y - 4)
        let offTag = try shape(PointThenDraw.plan(kind: .circle, pointInImagePixels: offPoint, label: "x",
                                                  controlFrameInDisplayPoints: frame, mapping: external))
        XCTAssertEqual(offTag.points[0].x, frameCentre.x, accuracy: 1e-9)
        XCTAssertEqual(offTag.points[0].y, frameCentre.y, accuracy: 1e-9)
        XCTAssertNotEqual(offTag.points[0], offPoint)
        XCTAssertEqual(tag.points[0].x, frameCentre.x, accuracy: 1e-9)
        let radius = Double(tag.points[1].x - tag.points[0].x)
        XCTAssertEqual(radius, 0.5 * hypot(96, 28) * 1.15 * 0.45, accuracy: 1e-9)
        XCTAssertEqual(radius, 25.875, accuracy: 1e-9)
        XCTAssertEqual(tag.points[1].y, tag.points[0].y)
    }

    func testAFrameThatIsNotOneControlFallsBackToTheDefaultRadius() throws {
        let point = CGPoint(x: 400, y: 300)
        let around = CGPoint(x: 400 / 0.45, y: 300 / 0.45)
        func radius(_ frame: CGRect?) throws -> Double {
            let tag = try shape(PointThenDraw.plan(kind: .circle, pointInImagePixels: point, label: nil,
                                                   controlFrameInDisplayPoints: frame, mapping: external))
            return Double(tag.points[1].x - tag.points[0].x)
        }
        let fallback = PointThenDraw.defaultRingRadiusInImagePixels
        // Wider than 300 pt, taller than 120 pt, empty, and a small frame elsewhere on the screen.
        XCTAssertEqual(try radius(CGRect(x: around.x - 200, y: around.y - 20, width: 301, height: 40)), fallback)
        XCTAssertEqual(try radius(CGRect(x: around.x - 50, y: around.y - 61, width: 100, height: 121)), fallback)
        XCTAssertEqual(try radius(CGRect(x: around.x, y: around.y, width: 0, height: 0)), fallback)
        XCTAssertEqual(try radius(CGRect(x: 10, y: 10, width: 60, height: 30)), fallback)
        // The largest frame that still counts as one control is used.
        XCTAssertEqual(try radius(CGRect(x: around.x - 150, y: around.y - 60, width: 300, height: 120)),
                       0.5 * hypot(300, 120) * 1.15 * 0.45, accuracy: 1e-9)
    }

    func testTheRingPointFlipsLeftWhenTheRingWouldLeaveTheScreenshot() throws {
        let tag = try shape(PointThenDraw.plan(kind: .circle, pointInImagePixels: CGPoint(x: 1140, y: 300), label: nil,
                                               controlFrameInDisplayPoints: nil, mapping: external))
        XCTAssertEqual(tag.points[1], CGPoint(x: 1110, y: 300))
    }

    // MARK: - arrow

    func testArrowTailGoesToTheSideWithMoreRoom() throws {
        // Point at x = 200 of 1152: far more room on the right than the left.
        let right = try shape(PointThenDraw.plan(kind: .arrow, pointInImagePixels: CGPoint(x: 200, y: 300), label: nil,
                                                 controlFrameInDisplayPoints: nil, mapping: external))
        XCTAssertEqual(right.points, [CGPoint(x: 290, y: 300), CGPoint(x: 200, y: 300)])
        // Point at x = 1000: more room on the left.
        let left = try shape(PointThenDraw.plan(kind: .arrow, pointInImagePixels: CGPoint(x: 1000, y: 300), label: nil,
                                                controlFrameInDisplayPoints: nil, mapping: external))
        XCTAssertEqual(left.points, [CGPoint(x: 910, y: 300), CGPoint(x: 1000, y: 300)])
        // On a tall display the room is vertical: near the top, the tail goes below.
        let below = try shape(PointThenDraw.plan(kind: .arrow, pointInImagePixels: CGPoint(x: 200, y: 100), label: nil,
                                                 controlFrameInDisplayPoints: nil, mapping: portrait))
        XCTAssertEqual(below.points, [CGPoint(x: 200, y: 190), CGPoint(x: 200, y: 100)])
        let above = try shape(PointThenDraw.plan(kind: .arrow, pointInImagePixels: CGPoint(x: 200, y: 700), label: nil,
                                                 controlFrameInDisplayPoints: nil, mapping: portrait))
        XCTAssertEqual(above.points, [CGPoint(x: 200, y: 610), CGPoint(x: 200, y: 700)])
    }

    func testArrowTieGoesLeft() throws {
        let tag = try shape(PointThenDraw.plan(kind: .arrow, pointInImagePixels: CGPoint(x: 576, y: 324), label: nil,
                                               controlFrameInDisplayPoints: nil, mapping: external))
        XCTAssertEqual(tag.points, [CGPoint(x: 486, y: 324), CGPoint(x: 576, y: 324)])
    }

    func testArrowTipTouchesTheFrameEdgeOnTheTailSide() throws {
        // A 96 x 28 pt control at (800, 600) pt: pixels x 360...403.2, y 270...282.6.
        let frame = CGRect(x: 800, y: 600, width: 96, height: 28)
        let point = CGPoint(x: 380, y: 276)
        let tag = try shape(PointThenDraw.plan(kind: .arrow, pointInImagePixels: point, label: nil,
                                               controlFrameInDisplayPoints: frame, mapping: external))
        // More room on the right, so the tip is the frame's right edge and the tail is 90 px beyond it.
        XCTAssertEqual(tag.points[1].x, 403.2, accuracy: 1e-9)
        XCTAssertEqual(tag.points[1].y, 276)
        XCTAssertEqual(tag.points[0].x, 403.2 + 90, accuracy: 1e-9)
        XCTAssertEqual(tag.points[0].y, 276)
    }

    func testArrowPointsStayInsideTheScreenshot() throws {
        let tag = try shape(PointThenDraw.plan(kind: .arrow, pointInImagePixels: CGPoint(x: 5, y: 5), label: nil,
                                               controlFrameInDisplayPoints: nil, mapping: external))
        for point in tag.points {
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1152, height: 648).contains(point))
        }
    }

    // MARK: - words and shape fields

    func testTheSentenceAndLabelComeFromThePointLabel() throws {
        let circle = PointThenDraw.plan(kind: .circle, pointInImagePixels: CGPoint(x: 400, y: 300), label: " The Settings Gear ",
                                        controlFrameInDisplayPoints: nil, mapping: external)
        XCTAssertEqual(circle.spokenSentence, "that is the settings gear, circled.")
        XCTAssertEqual(try shape(circle).label, "settings gear")
        let arrow = PointThenDraw.plan(kind: .arrow, pointInImagePixels: CGPoint(x: 400, y: 300), label: "save button",
                                       controlFrameInDisplayPoints: nil, mapping: external)
        XCTAssertEqual(arrow.spokenSentence, "that is the save button, marked with an arrow.")
        XCTAssertEqual(PointThenDraw.spokenSentence(kind: .circle, label: nil), "here it is, circled.")
        XCTAssertEqual(PointThenDraw.spokenSentence(kind: .arrow, label: "none"), "here it is, marked with an arrow.")
        XCTAssertNil(try shape(PointThenDraw.plan(kind: .circle, pointInImagePixels: .zero, label: "none",
                                                  controlFrameInDisplayPoints: nil, mapping: external)).label)
        XCTAssertFalse(circle.spokenSentence.contains("\u{2014}"))
    }

    func testThePlanIsATagTheOverlayAlreadyDraws() throws {
        let plan = PointThenDraw.plan(kind: .circle, pointInImagePixels: CGPoint(x: 400, y: 300), label: "x",
                                      controlFrameInDisplayPoints: nil, mapping: external)
        let overlay = MarkGeometryBuilder.overlayDrawing(from: plan.drawing, mapping: external)
        let geometry = MarkGeometryBuilder.geometry(for: overlay)
        XCTAssertTrue(geometry.passes.contains { !$0.isEmpty })
    }

    // MARK: - which requests are built from a point

    func testCircleAndArrowRequestsAreBuiltFromAPoint() {
        func kind(_ words: String, enabled: Bool = true) -> PointDrawKind? {
            DrawingIntent.pointThenDrawKind(words, pointThenDrawEnabled: enabled)
        }
        XCTAssertEqual(kind("circle the save button"), .circle)
        XCTAssertEqual(kind("draw a circle around the total"), .circle)
        XCTAssertEqual(kind("circle the undo arrow"), .circle)
        XCTAssertEqual(kind("draw an arrow to the settings gear"), .arrow)
        XCTAssertEqual(kind("put an arrow on the submit button and mark it"), .arrow)
        // A bare mark or "show me where" defaults to a circle.
        XCTAssertEqual(kind("mark this"), .circle)
        XCTAssertEqual(kind("show me where the settings are"), .circle)
    }

    func testOtherMarksAndBothAtOnceStayOnTheModelRoute() {
        func kind(_ words: String) -> PointDrawKind? {
            DrawingIntent.pointThenDrawKind(words, pointThenDrawEnabled: true)
        }
        XCTAssertNil(kind("underline the heading"))
        XCTAssertNil(kind("highlight the total"))
        XCTAssertNil(kind("draw a box around the form"))
        XCTAssertNil(kind("draw a line under the title"))
        XCTAssertNil(kind("outline this"))
        XCTAssertNil(kind("circle the button and draw an arrow to it"))
        // Not a drawing request at all.
        XCTAssertNil(kind("what is a circle"))
        XCTAssertNil(kind("mark it as read"))
    }

    func testTheFlagSendsCircleAndArrowBackToTheModelRoute() {
        XCTAssertNil(DrawingIntent.pointThenDrawKind("circle the save button", pointThenDrawEnabled: false))
        XCTAssertNil(DrawingIntent.pointThenDrawKind("draw an arrow to the gear", pointThenDrawEnabled: false))
        let suite = UserDefaults(suiteName: "PointThenDrawTests-\(UUID().uuidString)")!
        XCTAssertTrue(PointThenDraw.isEnabled(defaults: suite))
        suite.set(true, forKey: PointThenDraw.modelShapeTagFlagKey)
        XCTAssertFalse(PointThenDraw.isEnabled(defaults: suite))
    }

    // MARK: - Core Graphics frames to display-local frames

    func testACGGlobalFrameMapsToDisplayLocalPoints() {
        // A second display to the right of a 1512 x 982 pt primary, same height:
        // global AppKit frame (1512, 0, 2560, 1440); AppKit y 0 is its bottom.
        let secondary = ScreenMapping(displayFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                      displayWidthInPoints: 2560, displayHeightInPoints: 1440,
                                      screenshotWidthInPixels: 1152, screenshotHeightInPixels: 648)
        let primaryHeight: CGFloat = 982
        let local = CGPoint(x: 300, y: 200)
        let cg = secondary.cgGlobalPoint(forDisplayLocalPoint: local, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(secondary.displayLocalPoint(forCGGlobalPoint: cg, primaryScreenHeight: primaryHeight), local)
        let rect = CGRect(x: cg.x, y: cg.y, width: 80, height: 24)
        XCTAssertEqual(secondary.displayLocalRect(forCGGlobalRect: rect, primaryScreenHeight: primaryHeight),
                       CGRect(x: 300, y: 200, width: 80, height: 24))
    }
}

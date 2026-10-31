import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class MarkGeometryTests: XCTestCase {
    private typealias Builder = MarkGeometryBuilder

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }

    // MARK: - circle

    func testCirclePointsLieOnTheRingAndStartAtTheRingPoint() {
        let centre = CGPoint(x: 200, y: 150)
        let ring = CGPoint(x: 250, y: 150)
        let points = Builder.circlePoints(centre: centre, ringPoint: ring)
        XCTAssertGreaterThanOrEqual(points.count, 24)
        XCTAssertLessThanOrEqual(points.count, 72)
        XCTAssertEqual(Double(points[0].x), 250, accuracy: 1e-9)
        XCTAssertEqual(Double(points[0].y), 150, accuracy: 1e-9)
        for point in points { XCTAssertEqual(distance(point, centre), 50, accuracy: 1e-9) }
        XCTAssertNotEqual(points.first, points.last, "the ring is closed by the flag, not by repeating a point")
    }

    func testCircleWithTheRingPointOnTheCentreGetsAMinimumRadius() {
        let points = Builder.circlePoints(centre: CGPoint(x: 10, y: 10), ringPoint: CGPoint(x: 10, y: 10))
        for point in points { XCTAssertEqual(distance(point, CGPoint(x: 10, y: 10)), Builder.minimumCircleRadius, accuracy: 1e-9) }
    }

    func testBiggerCirclesGetMorePointsUpToTheCap() {
        let small = Builder.circlePoints(centre: .zero, ringPoint: CGPoint(x: 20, y: 0)).count
        let large = Builder.circlePoints(centre: .zero, ringPoint: CGPoint(x: 300, y: 0)).count
        XCTAssertLessThan(small, large)
        XCTAssertEqual(large, 72)
    }

    // MARK: - curve

    func testCatmullRomPassesThroughEveryInputPoint() {
        let input = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 40), CGPoint(x: 100, y: 0), CGPoint(x: 150, y: 60)]
        let curve = Builder.catmullRom(input, samplesPerSegment: 12)
        XCTAssertEqual(curve.count, 1 + 12 * 3)
        XCTAssertEqual(curve.first, input.first)
        XCTAssertEqual(curve.last, input.last)
        for (index, point) in input.enumerated().dropFirst() {
            let sampled = curve[index * 12]
            XCTAssertEqual(Double(sampled.x), Double(point.x), accuracy: 1e-9)
            XCTAssertEqual(Double(sampled.y), Double(point.y), accuracy: 1e-9)
        }
    }

    func testCatmullRomIsSmoothBetweenPoints() {
        // A curve through a corner must round it: the samples near the corner are
        // not on either straight edge.
        let curve = Builder.catmullRom([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)], samplesPerSegment: 12)
        let nearCorner = curve[10]
        XCTAssertNotEqual(nearCorner.y, 0)
    }

    func testCatmullRomWithTwoPointsIsUnchanged() {
        let two = [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]
        XCTAssertEqual(Builder.catmullRom(two, samplesPerSegment: 12), two)
    }

    // MARK: - arrow

    func testArrowheadSitsOnTheTipWithBarbsAtTheSetAngle() {
        let tail = CGPoint(x: 0, y: 0)
        let tip = CGPoint(x: 200, y: 0)
        let head = Builder.arrowhead(tail: tail, tip: tip)
        XCTAssertEqual(head.count, 3)
        XCTAssertEqual(head[1], tip)
        // 200 pt shaft: a quarter would be 50, so the head is capped at 24.
        XCTAssertEqual(distance(head[0], tip), 24, accuracy: 1e-9)
        XCTAssertEqual(distance(head[2], tip), 24, accuracy: 1e-9)
        // Barbs trail back toward the tail, on both sides of the shaft.
        XCTAssertLessThan(head[0].x, tip.x)
        XCTAssertLessThan(head[2].x, tip.x)
        XCTAssertEqual(Double(head[0].y), -Double(head[2].y), accuracy: 1e-9)
        let angle = atan2(abs(Double(head[0].y)), Double(tip.x - head[0].x)) * 180 / Double.pi
        XCTAssertEqual(angle, Builder.arrowheadAngleDegrees, accuracy: 1e-6)
    }

    func testShortArrowGetsTheMinimumHeadAndADegenerateOneDoesNotCrash() {
        let short = Builder.arrowhead(tail: CGPoint(x: 0, y: 0), tip: CGPoint(x: 20, y: 0))
        XCTAssertEqual(distance(short[0], short[1]), 10, accuracy: 1e-9)
        XCTAssertEqual(Builder.arrowhead(tail: .zero, tip: .zero).count, 3)
    }

    func testArrowFollowsADiagonalShaft() {
        let head = Builder.arrowhead(tail: CGPoint(x: 0, y: 0), tip: CGPoint(x: 100, y: 100))
        // Both barbs are behind the tip along the shaft direction.
        for barb in [head[0], head[2]] {
            XCTAssertLessThan(Double(barb.x + barb.y), 200)
        }
    }

    // MARK: - lines, polygons, boxes

    func testSampledLineKeepsTheEndsAndTheSpacing() {
        let line = Builder.sampledLine(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        XCTAssertEqual(line.first, CGPoint(x: 0, y: 0))
        XCTAssertEqual(line.last, CGPoint(x: 100, y: 0))
        XCTAssertEqual(line.count, 11)
        let tiny = Builder.sampledLine(from: .zero, to: CGPoint(x: 3, y: 0))
        XCTAssertEqual(tiny.count, 3, "a short line still has two segments to bend")
    }

    func testPolygonPointsRunAroundTheCornersWithoutRepeating() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        let points = Builder.polygonPoints(corners)
        XCTAssertEqual(points.count, 40)
        XCTAssertEqual(points.first, corners[0])
        XCTAssertTrue(points.contains(corners[2]))
        for index in points.indices {
            XCTAssertNotEqual(points[index], points[(index + 1) % points.count], "no repeated neighbour")
        }
    }

    func testRoundedRectStaysInsideItsRectAndHasNoRepeatedNeighbours() {
        let rect = CGRect(x: 40, y: 60, width: 220, height: 36)
        let points = Builder.roundedRectPoints(rect, radius: 8)
        let slack = rect.insetBy(dx: -1e-6, dy: -1e-6)
        for point in points { XCTAssertTrue(slack.contains(point), "\(point)") }
        for index in points.indices {
            XCTAssertGreaterThan(distance(points[index], points[(index + 1) % points.count]), 1e-6)
        }
        // The box touches all four sides.
        XCTAssertEqual(points.map { Double($0.x) }.min() ?? 0, Double(rect.minX), accuracy: 1e-6)
        XCTAssertEqual(points.map { Double($0.x) }.max() ?? 0, Double(rect.maxX), accuracy: 1e-6)
        XCTAssertEqual(points.map { Double($0.y) }.min() ?? 0, Double(rect.minY), accuracy: 1e-6)
        XCTAssertEqual(points.map { Double($0.y) }.max() ?? 0, Double(rect.maxY), accuracy: 1e-6)
    }

    func testRoundedRectCornerRadiusIsCappedByTheSmallSide() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 10)
        let points = Builder.roundedRectPoints(rect, radius: 50)
        let slack = rect.insetBy(dx: -1e-6, dy: -1e-6)
        for point in points { XCTAssertTrue(slack.contains(point)) }
    }

    // MARK: - jitter

    func testJitterIsBoundedAndDeterministic() {
        let points = (0..<200).map { CGPoint(x: Double($0) * 3, y: 50) }
        let a = Builder.jitter(points, seed: 42, maxOffset: 1.0)
        let b = Builder.jitter(points, seed: 42, maxOffset: 1.0)
        let c = Builder.jitter(points, seed: 43, maxOffset: 1.0)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        for (moved, original) in zip(a, points) { XCTAssertLessThanOrEqual(distance(moved, original), 1.0 + 1e-9) }
        XCTAssertTrue(zip(a, points).contains { distance($0, $1) > 0.1 }, "it actually moves points")
    }

    func testZeroOffsetJitterChangesNothing() {
        let points = [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]
        XCTAssertEqual(Builder.jitter(points, seed: 7, maxOffset: 0), points)
    }

    // MARK: - the full figure

    private let circle = OverlayDrawing.shape(kind: .circle, points: [CGPoint(x: 300, y: 200), CGPoint(x: 340, y: 200)])
    private let arrow = OverlayDrawing.shape(kind: .arrow, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 220)])
    private let box = OverlayDrawing.highlight(rect: CGRect(x: 50, y: 50, width: 200, height: 30))

    func testEveryKindMakesTwoPasses() {
        let drawings: [OverlayDrawing] = [
            circle, arrow, box,
            .shape(kind: .line, points: [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0)]),
            .shape(kind: .curve, points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 30), CGPoint(x: 100, y: 0)]),
            .shape(kind: .polygon, points: [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0), CGPoint(x: 30, y: 50)]),
        ]
        for drawing in drawings {
            let geometry = Builder.geometry(for: drawing)
            XCTAssertEqual(geometry.passes.count, Builder.passCount)
            XCTAssertEqual(geometry.passes[0].count, geometry.passes[1].count)
            XCTAssertFalse(geometry.passes[0].isEmpty)
        }
    }

    func testTheSecondPassIsWithinOneAndAHalfPointsOfTheFirst() {
        for drawing in [circle, arrow, box,
                        OverlayDrawing.shape(kind: .curve, points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 30), CGPoint(x: 100, y: 0)])] {
            let geometry = Builder.geometry(for: drawing)
            var checked = 0
            for (first, second) in zip(geometry.passes[0], geometry.passes[1]) {
                XCTAssertEqual(first.points.count, second.points.count)
                XCTAssertEqual(first.isClosed, second.isClosed)
                for (a, b) in zip(first.points, second.points) {
                    XCTAssertLessThanOrEqual(distance(a, b), Builder.maxPassOffset + 1e-9)
                    checked += 1
                }
            }
            XCTAssertGreaterThan(checked, 4)
        }
    }

    func testEachPassStaysCloseToTheCleanFigure() {
        let base = Builder.baseSubpaths(for: circle)
        let geometry = Builder.geometry(for: circle)
        for pass in geometry.passes {
            for (clean, drawn) in zip(base, pass) {
                for (a, b) in zip(clean.points, drawn.points) { XCTAssertLessThanOrEqual(distance(a, b), 1.0 + 1e-9) }
            }
        }
        XCTAssertNotEqual(geometry.passes[0], geometry.passes[1])
    }

    func testTheSketchIsTheSameEveryTime() {
        XCTAssertEqual(Builder.geometry(for: arrow), Builder.geometry(for: arrow))
        XCTAssertNotEqual(Builder.geometry(for: circle), Builder.geometry(for: OverlayDrawing.shape(kind: .circle, points: [CGPoint(x: 300, y: 201), CGPoint(x: 340, y: 200)])))
    }

    func testClosedAndOpenFlags() {
        XCTAssertEqual(Builder.geometry(for: circle).passes[0].map(\.isClosed), [true])
        XCTAssertEqual(Builder.geometry(for: box).passes[0].map(\.isClosed), [true])
        XCTAssertEqual(Builder.geometry(for: arrow).passes[0].map(\.isClosed), [false, false], "shaft and head, both open")
        let polygon = OverlayDrawing.shape(kind: .polygon, points: [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0), CGPoint(x: 30, y: 50)])
        XCTAssertEqual(Builder.geometry(for: polygon).passes[0].map(\.isClosed), [true])
        let curve = OverlayDrawing.shape(kind: .curve, points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 30), CGPoint(x: 100, y: 0)])
        XCTAssertEqual(Builder.geometry(for: curve).passes[0].map(\.isClosed), [false])
    }

    func testMalformedDrawingsMakeNothing() {
        XCTAssertTrue(Builder.baseSubpaths(for: .shape(kind: .circle, points: [CGPoint(x: 1, y: 1)])).isEmpty)
        XCTAssertTrue(Builder.baseSubpaths(for: .highlight(rect: .zero)).isEmpty)
        XCTAssertTrue(Builder.geometry(for: .highlight(rect: .zero)).passes.allSatisfy(\.isEmpty))
    }

    func testSeedDependsOnTheKindAndTheCoordinates() {
        XCTAssertEqual(Builder.seed(for: circle), Builder.seed(for: circle))
        XCTAssertNotEqual(Builder.seed(for: circle),
                          Builder.seed(for: .shape(kind: .line, points: [CGPoint(x: 300, y: 200), CGPoint(x: 340, y: 200)])))
        XCTAssertNotEqual(Builder.seed(for: box), Builder.seed(for: .highlight(rect: CGRect(x: 50, y: 50, width: 200, height: 31))))
    }

    // MARK: - tag to overlay

    private let mapping = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 500, height: 250),
                                        displayWidthInPoints: 500, displayHeightInPoints: 250,
                                        screenshotWidthInPixels: 1000, screenshotHeightInPixels: 500)

    func testShapePointsMapFromPixelsToOverlayPoints() {
        let tag = ShapeTag(kind: .circle, points: [CGPoint(x: 600, y: 300), CGPoint(x: 700, y: 300)], label: nil, screenNumber: nil)
        let mapped = Builder.overlayDrawing(from: .shape(tag), mapping: mapping)
        XCTAssertEqual(mapped, .shape(kind: .circle, points: [CGPoint(x: 300, y: 150), CGPoint(x: 350, y: 150)]))
    }

    func testHighlightRectMapsAndPointsOutsideTheImageAreClamped() {
        let tag = HighlightTag(rect: CGRect(x: 200, y: 100, width: 400, height: 200), label: nil, screenNumber: nil)
        XCTAssertEqual(Builder.overlayDrawing(from: .highlight(tag), mapping: mapping),
                       .highlight(rect: CGRect(x: 100, y: 50, width: 200, height: 100)))
        let outside = ShapeTag(kind: .line, points: [CGPoint(x: -50, y: 20), CGPoint(x: 5000, y: 900)], label: nil, screenNumber: nil)
        XCTAssertEqual(Builder.overlayDrawing(from: .shape(outside), mapping: mapping),
                       .shape(kind: .line, points: [CGPoint(x: 0, y: 10), CGPoint(x: 500, y: 250)]))
    }

    func testMappingOnASecondDisplayUsesDisplayLocalPoints() {
        // The overlay of a display placed to the right of the primary one draws
        // in its own local space, not in global points.
        let right = ScreenMapping(displayFrame: CGRect(x: 1512, y: 0, width: 500, height: 250),
                                  displayWidthInPoints: 500, displayHeightInPoints: 250,
                                  screenshotWidthInPixels: 1000, screenshotHeightInPixels: 500)
        let tag = ShapeTag(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 500)], label: nil, screenNumber: 2)
        XCTAssertEqual(Builder.overlayDrawing(from: .shape(tag), mapping: right),
                       .shape(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 250)]))
    }
}

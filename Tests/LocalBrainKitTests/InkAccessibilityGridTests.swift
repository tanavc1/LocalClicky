import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class InkAccessibilityGridTests: XCTestCase {
    private func circle(center: CGPoint = CGPoint(x: 500, y: 400), radius: Double = 80) -> [InkSample] {
        (0...48).map { step in
            let angle = 2 * Double.pi * Double(step) / 48
            return InkSample(point: CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)),
                             time: Double(step) * 0.016)
        }
    }

    func testGridIsSixBySixCellCentres() {
        let points = InkAccessibilityGrid.probePoints(in: CGRect(x: 0, y: 0, width: 60, height: 120))
        XCTAssertEqual(points.count, 36)
        XCTAssertEqual(points.first, CGPoint(x: 5, y: 10))
        XCTAssertEqual(points[5], CGPoint(x: 55, y: 10))
        XCTAssertEqual(points.last, CGPoint(x: 55, y: 110))
    }

    func testPointsStayInsideTheBounds() {
        let bounds = CGRect(x: 100, y: 200, width: 300, height: 90)
        for point in InkAccessibilityGrid.probePoints(in: bounds) {
            XCTAssertTrue(bounds.contains(point))
        }
    }

    func testExtraPointsFollowTheGrid() {
        let extra = CGPoint(x: 7, y: 8)
        let points = InkAccessibilityGrid.probePoints(in: CGRect(x: 0, y: 0, width: 60, height: 60), extraPoints: [extra])
        XCTAssertEqual(points.count, 37)
        XCTAssertEqual(points.last, extra)
    }

    func testDuplicatesAreRemovedAndADegenerateBoxCollapses() {
        let points = InkAccessibilityGrid.probePoints(in: CGRect(x: 10, y: 10, width: 0, height: 0),
                                                      extraPoints: [CGPoint(x: 10, y: 10)])
        XCTAssertEqual(points, [CGPoint(x: 10, y: 10)])
    }

    func testBoundsOfACircleMarkMatchTheMarkBox() throws {
        let analysis = InkStroke(samples: circle()).analyze()
        let bounds = try XCTUnwrap(InkAccessibilityGrid.bounds(of: analysis))
        XCTAssertEqual(bounds, analysis.marks[0].boundingBox)
    }

    func testBoundsOfAPauseOnlyStrokeIsABoxAroundThePause() throws {
        let dwell = InkDwell(location: CGPoint(x: 300, y: 200), duration: 1, startTime: 0, sampleRange: 0...1)
        let bounds = try XCTUnwrap(InkAccessibilityGrid.bounds(of: InkAnalysis(marks: [], dwells: [dwell])))
        XCTAssertEqual(bounds, CGRect(x: 276, y: 176, width: 48, height: 48))
    }

    func testEmptyAnalysisHasNoBoundsAndNoProbes() {
        XCTAssertNil(InkAccessibilityGrid.bounds(of: .empty))
        XCTAssertTrue(InkAccessibilityGrid.probePoints(for: .empty).isEmpty)
    }

    func testProbePointsForAnalysisIncludeTheMarkCentre() {
        let analysis = InkStroke(samples: circle()).analyze()
        let points = InkAccessibilityGrid.probePoints(for: analysis)
        XCTAssertTrue(points.contains(analysis.marks[0].center))
        XCTAssertGreaterThanOrEqual(points.count, 36)
    }
}

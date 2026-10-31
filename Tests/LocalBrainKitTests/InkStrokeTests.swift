import XCTest
import CoreGraphics
@testable import LocalBrainKit

/// Synthetic stroke builders shared by the ink tests.
enum InkFixtures {
    static let dt = 0.016

    /// A circle (or arc) of `degrees` of turning starting at angle 0.
    static func circle(center: CGPoint = CGPoint(x: 500, y: 400), radius: CGFloat = 80,
                       degrees: Double = 360, steps: Int = 48, startTime: Double = 0) -> [InkSample] {
        (0...steps).map { step in
            let angle = degrees * Double.pi / 180 * Double(step) / Double(steps)
            return InkSample(point: CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                                            y: center.y + radius * CGFloat(sin(angle))),
                             time: startTime + Double(step) * dt)
        }
    }

    /// A straight run with small deterministic wobble perpendicular-ish to it.
    static func line(from a: CGPoint, to b: CGPoint, steps: Int = 30, wobble: CGFloat = 1.0,
                     startTime: Double = 0) -> [InkSample] {
        (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            let noise = wobble * CGFloat(sin(Double(step) * 2.7))
            return InkSample(point: CGPoint(x: a.x + (b.x - a.x) * t + noise,
                                            y: a.y + (b.y - a.y) * t - noise),
                             time: startTime + Double(step) * dt)
        }
    }

    /// A back-and-forth zigzag of `amplitude` across `width`.
    static func scribble(origin: CGPoint = CGPoint(x: 200, y: 200), width: CGFloat = 160,
                         amplitude: CGFloat = 40, zigs: Int = 6, startTime: Double = 0) -> [InkSample] {
        var samples: [InkSample] = []
        let perZig = 6
        for zig in 0..<(zigs * perZig + 1) {
            let t = CGFloat(zig) / CGFloat(zigs * perZig)
            let phase = Double(zig) / Double(perZig) * Double.pi
            samples.append(InkSample(point: CGPoint(x: origin.x + width * t,
                                                    y: origin.y + amplitude * CGFloat(sin(phase))),
                                     time: startTime + Double(zig) * dt))
        }
        return samples
    }

    /// Samples that hold nearly still at `location` for `duration` seconds.
    static func hold(at location: CGPoint, duration: Double, startTime: Double,
                     step: Double = 0.05) -> [InkSample] {
        let count = Int(duration / step)
        return (0...count).map { index in
            let jitter = CGFloat(index % 2 == 0 ? 1.5 : -1.5)
            return InkSample(point: CGPoint(x: location.x + jitter, y: location.y - jitter),
                             time: startTime + Double(index) * step)
        }
    }
}

final class InkStrokeTests: XCTestCase {
    func testPathLengthAndBoundingBox() {
        let stroke = InkStroke(samples: [InkSample(point: CGPoint(x: 0, y: 0), time: 0),
                                         InkSample(point: CGPoint(x: 30, y: 40), time: 0.1),
                                         InkSample(point: CGPoint(x: 30, y: 100), time: 0.2)])
        XCTAssertEqual(stroke.pathLength, 110, accuracy: 1e-9)
        XCTAssertEqual(stroke.boundingBox, CGRect(x: 0, y: 0, width: 30, height: 100))
        XCTAssertEqual(stroke.duration, 0.2, accuracy: 1e-9)
    }

    func testEmptyStroke() {
        let stroke = InkStroke(samples: [])
        XCTAssertEqual(stroke.pathLength, 0)
        XCTAssertNil(stroke.boundingBox)
        XCTAssertTrue(stroke.isJiggle)
        XCTAssertTrue(stroke.analyze().isEmpty)
        XCTAssertTrue(stroke.marks().isEmpty)
    }

    func testSimplifyCollapsesNoisyLineToTwoPoints() {
        let stroke = InkStroke(samples: InkFixtures.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 300, y: 0), wobble: 0.5))
        XCTAssertEqual(stroke.simplified(tolerance: 3).count, 2)
    }

    func testSimplifyKeepsCornerAndEndpoints() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0),
                      CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 100)]
        let simplified = InkGeometry.simplify(points, tolerance: 1)
        XCTAssertEqual(simplified, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)])
    }

    func testSimplifyZeroToleranceKeepsBends() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 1), CGPoint(x: 20, y: 0)]
        XCTAssertEqual(InkGeometry.simplify(points, tolerance: 0), points)
    }

    func testSimplifyHandlesClosedLoop() {
        let loop = InkFixtures.circle().map(\.point)
        let simplified = InkGeometry.simplify(loop, tolerance: 2)
        XCTAssertGreaterThan(simplified.count, 8)
        XCTAssertLessThan(simplified.count, loop.count)
    }

    // MARK: - Jiggle

    func testJiggleIsRejected() {
        var samples: [InkSample] = []
        for index in 0..<8 {
            let dx: CGFloat = index % 2 == 0 ? 0 : 3
            let dy: CGFloat = index % 3 == 0 ? 0 : 1
            samples.append(InkSample(point: CGPoint(x: 400 + dx, y: 300 + dy), time: Double(index) * 0.02))
        }
        let stroke = InkStroke(samples: samples)
        XCTAssertLessThan(stroke.pathLength, 30)
        XCTAssertTrue(stroke.isJiggle)
        XCTAssertTrue(stroke.analyze().isEmpty)
    }

    func testJustOverThresholdIsInk() {
        let stroke = InkStroke(samples: InkFixtures.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 40, y: 0), steps: 5, wobble: 0))
        XCTAssertFalse(stroke.isJiggle)
        XCTAssertEqual(stroke.marks().count, 1)
    }

    // MARK: - Classification

    func testFullCircleIsCircle() {
        let marks = InkStroke(samples: InkFixtures.circle()).marks()
        XCTAssertEqual(marks.map(\.kind), [.circle])
    }

    func testSlightlyOpenOverlappingCircleIsCircle() {
        // 345 degrees: closed within 25 percent of the diagonal and enclosing.
        XCTAssertEqual(InkStroke(samples: InkFixtures.circle(degrees: 345)).marks().map(\.kind), [.circle])
        // Overshoot past the start still counts.
        XCTAssertEqual(InkStroke(samples: InkFixtures.circle(degrees: 400)).marks().map(\.kind), [.circle])
    }

    func testCounterClockwiseCircleIsCircle() {
        XCTAssertEqual(InkStroke(samples: InkFixtures.circle(degrees: -360)).marks().map(\.kind), [.circle])
    }

    func testHalfCircleIsNotACircle() {
        let kinds = InkStroke(samples: InkFixtures.circle(degrees: 180)).marks().map(\.kind)
        XCTAssertEqual(kinds.count, 1)
        XCTAssertNotEqual(kinds.first, .circle)
    }

    func testQuarterArcsAreNotCircles() {
        XCTAssertNotEqual(InkStroke(samples: InkFixtures.circle(degrees: 270)).marks().first?.kind, .circle)
    }

    func testNoisyStraightLinesAreLines() {
        let horizontal = InkStroke(samples: InkFixtures.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 110))).marks()
        XCTAssertEqual(horizontal.map(\.kind), [.line])
        let diagonal = InkStroke(samples: InkFixtures.line(from: CGPoint(x: 600, y: 600), to: CGPoint(x: 200, y: 150))).marks()
        XCTAssertEqual(diagonal.map(\.kind), [.line])
        XCTAssertEqual(diagonal[0].start.x, 600, accuracy: 2)
        XCTAssertEqual(diagonal[0].end.y, 150, accuracy: 2)
    }

    func testZigzagIsScribble() {
        XCTAssertEqual(InkStroke(samples: InkFixtures.scribble()).marks().map(\.kind), [.scribble])
    }

    func testOutAndBackIsScribble() {
        var samples = InkFixtures.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), wobble: 0)
        let back = InkFixtures.line(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 110, y: 104), wobble: 0, startTime: 0.5)
        samples += back
        XCTAssertEqual(InkStroke(samples: samples).marks().map(\.kind), [.scribble])
    }

    // MARK: - Dwells and splitting

    func testDwellIsDetectedWithLocationAndDuration() {
        var samples = InkFixtures.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), wobble: 0)
        samples += InkFixtures.hold(at: CGPoint(x: 300, y: 100), duration: 0.8, startTime: 0.5)
        let dwells = InkStroke(samples: samples).dwells()
        XCTAssertEqual(dwells.count, 1)
        XCTAssertEqual(dwells[0].location.x, 300, accuracy: 6)
        XCTAssertEqual(dwells[0].location.y, 100, accuracy: 6)
        XCTAssertGreaterThanOrEqual(dwells[0].duration, 0.8)
    }

    func testShortPauseIsNotADwell() {
        var samples = InkFixtures.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), wobble: 0)
        samples += InkFixtures.hold(at: CGPoint(x: 300, y: 100), duration: 0.3, startTime: 0.5)
        XCTAssertTrue(InkStroke(samples: samples).dwells().isEmpty)
    }

    func testPauseOutsideTheRadiusIsNotADwell() {
        // Slow drift of 30 points over a second: never inside 12 points for 0.6 s.
        let samples = (0...20).map { InkSample(point: CGPoint(x: 100 + Double($0) * 1.5, y: 100), time: Double($0) * 0.05) }
        XCTAssertTrue(InkStroke(samples: samples).dwells(minimumDuration: 0.6, radius: 12).isEmpty)
    }

    func testStationaryMouseGapCountsAsDwell() {
        // A mouse that stops emits no events, so the pause is one long gap.
        var samples = InkFixtures.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), wobble: 0)
        let pauseStart = samples[samples.count - 1].time
        samples.append(InkSample(point: CGPoint(x: 300, y: 250), time: pauseStart + 1.2))
        samples.append(InkSample(point: CGPoint(x: 300, y: 400), time: pauseStart + 1.3))
        let dwells = InkStroke(samples: samples).dwells()
        XCTAssertEqual(dwells.count, 1)
        XCTAssertEqual(dwells[0].duration, 1.2, accuracy: 0.05)
    }

    func testThresholdsAreDocumentedValues() {
        XCTAssertEqual(InkStroke.dwellReportDuration, 0.35)
        XCTAssertEqual(InkStroke.markSplitDuration, 0.6)
        XCTAssertEqual(InkStroke.dwellRadius, 12)
        XCTAssertEqual(InkStroke.liveTrailThreshold, 8)
        XCTAssertEqual(InkStroke.minimumSampleSpacing, 1.5)
    }

    func testPauseBetweenReportAndSplitIsReportedButDoesNotSplit() {
        var samples = InkFixtures.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), wobble: 0)
        samples += InkFixtures.hold(at: CGPoint(x: 300, y: 100), duration: 0.45, startTime: 0.5)
        let afterHold = samples[samples.count - 1].time
        samples += InkFixtures.line(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 300, y: 320), wobble: 0, startTime: afterHold + 0.02)
        let stroke = InkStroke(samples: samples)
        let analysis = stroke.analyze()
        XCTAssertEqual(analysis.dwells.count, 1)
        XCTAssertGreaterThanOrEqual(analysis.dwells[0].duration, 0.35)
        XCTAssertLessThan(analysis.dwells[0].duration, 0.6)
        XCTAssertEqual(analysis.marks.count, 1)
        XCTAssertEqual(stroke.marks().count, 1)
    }

    func testPauseUnderReportThresholdIsNotReported() {
        var samples = InkFixtures.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), wobble: 0)
        samples += InkFixtures.hold(at: CGPoint(x: 300, y: 100), duration: 0.15, startTime: 0.5)
        samples += InkFixtures.line(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 300, y: 320), wobble: 0, startTime: 0.67)
        XCTAssertTrue(InkStroke(samples: samples).analyze().dwells.isEmpty)
    }

    func testSampleSpacingKeepsFirstFarAndFinalButDropsClose() {
        let last = CGPoint(x: 100, y: 100)
        XCTAssertTrue(InkStroke.shouldKeepSample(CGPoint(x: 100, y: 100), after: nil))
        XCTAssertFalse(InkStroke.shouldKeepSample(CGPoint(x: 101, y: 100.5), after: last))
        XCTAssertTrue(InkStroke.shouldKeepSample(CGPoint(x: 101.5, y: 100), after: last))
        XCTAssertTrue(InkStroke.shouldKeepSample(CGPoint(x: 102, y: 100), after: last))
        XCTAssertFalse(InkStroke.shouldKeepSample(last, after: last))
        XCTAssertTrue(InkStroke.shouldKeepSample(last, after: last, isFinal: true))
    }

    func testDwellSplitsTheStrokeIntoTwoMarks() {
        var samples = InkFixtures.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), wobble: 0)
        samples += InkFixtures.hold(at: CGPoint(x: 300, y: 100), duration: 0.8, startTime: 0.5)
        let afterHold = samples[samples.count - 1].time
        samples += InkFixtures.line(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 300, y: 320), wobble: 0, startTime: afterHold + 0.02)
        let analysis = InkStroke(samples: samples).analyze()
        XCTAssertEqual(analysis.dwells.count, 1)
        XCTAssertEqual(analysis.marks.map(\.kind), [.line, .line])
        XCTAssertLessThan(analysis.marks[0].end.x, 305)
        XCTAssertGreaterThan(analysis.marks[0].end.x, 280)
        XCTAssertLessThan(analysis.marks[0].endTime, analysis.marks[1].startTime + 1e-9)
        XCTAssertEqual(analysis.marks[1].end.y, 320, accuracy: 2)
    }

    func testCircleThenDwellThenLine() {
        var samples = InkFixtures.circle()
        let circleEnd = samples[samples.count - 1]
        samples += InkFixtures.hold(at: circleEnd.point, duration: 0.9, startTime: circleEnd.time + 0.05)
        let holdEnd = samples[samples.count - 1].time
        samples += InkFixtures.line(from: circleEnd.point, to: CGPoint(x: 800, y: 700), wobble: 0, startTime: holdEnd + 0.02)
        let analysis = InkStroke(samples: samples).analyze()
        XCTAssertEqual(analysis.marks.map(\.kind), [.circle, .line])
        XCTAssertEqual(analysis.dwells.count, 1)
    }

    func testTinyLeftoverPiecesAreDropped() {
        // A dwell at the very start and end leaves no marks beyond the real one.
        var samples = InkFixtures.hold(at: CGPoint(x: 100, y: 100), duration: 0.8, startTime: 0)
        let t = samples[samples.count - 1].time + 0.02
        samples += InkFixtures.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 100), wobble: 0, startTime: t)
        let end = samples[samples.count - 1]
        samples += InkFixtures.hold(at: end.point, duration: 0.8, startTime: end.time + 0.05)
        let analysis = InkStroke(samples: samples).analyze()
        XCTAssertEqual(analysis.marks.count, 1)
        XCTAssertEqual(analysis.dwells.count, 2)
    }

    // MARK: - Regions

    func testRegionGridNames() {
        let screen = CGSize(width: 900, height: 600)
        func name(_ x: CGFloat, _ y: CGFloat) -> String { InkRegion.name(for: CGPoint(x: x, y: y), in: screen) }
        XCTAssertEqual(name(10, 10), "top left")
        XCTAssertEqual(name(450, 10), "top")
        XCTAssertEqual(name(890, 10), "top right")
        XCTAssertEqual(name(10, 300), "left")
        XCTAssertEqual(name(450, 300), "center")
        XCTAssertEqual(name(890, 300), "right")
        XCTAssertEqual(name(10, 590), "bottom left")
        XCTAssertEqual(name(450, 590), "bottom")
        XCTAssertEqual(name(890, 590), "bottom right")
    }

    func testRegionClampsOutsidePoints() {
        let screen = CGSize(width: 900, height: 600)
        XCTAssertEqual(InkRegion.region(for: CGPoint(x: -50, y: -50), in: screen), .topLeft)
        XCTAssertEqual(InkRegion.region(for: CGPoint(x: 5000, y: 5000), in: screen), .bottomRight)
        XCTAssertEqual(InkRegion.region(for: CGPoint(x: 900, y: 600), in: screen), .bottomRight)
        XCTAssertEqual(InkRegion.region(for: CGPoint(x: 1, y: 1), in: .zero), .center)
    }
}

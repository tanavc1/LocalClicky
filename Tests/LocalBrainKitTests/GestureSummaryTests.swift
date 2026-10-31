import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class GestureSummaryTests: XCTestCase {
    private let screen = CGSize(width: 1200, height: 900)

    private func mark(_ kind: InkMarkKind, from start: CGPoint, to end: CGPoint, center: CGPoint? = nil) -> InkMark {
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(end.x - start.x), height: abs(end.y - start.y))
        let c = center ?? CGPoint(x: box.midX, y: box.midY)
        let wide = box.union(CGRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2))
        return InkMark(kind: kind, points: [start, end], boundingBox: center == nil ? box : wide,
                       pathLength: 100, startTime: 0, endTime: 1)
    }

    private func dwell(at location: CGPoint, seconds: Double) -> InkDwell {
        InkDwell(location: location, duration: seconds, startTime: 0, sampleRange: 0...1)
    }

    func testSpecExampleSentence() {
        let analysis = InkAnalysis(
            marks: [mark(.circle, from: CGPoint(x: 940, y: 100), to: CGPoint(x: 1060, y: 140), center: CGPoint(x: 1000, y: 120)),
                    mark(.line, from: CGPoint(x: 600, y: 450), to: CGPoint(x: 600, y: 850))],
            dwells: [dwell(at: CGPoint(x: 600, y: 450), seconds: 1.0)])
        XCTAssertEqual(GestureSummary.describe(analysis, screenSize: screen),
                       "The user drew 2 marks in order while speaking: 1) circled an area in the top right; "
                       + "2) drew a line from the center toward the bottom; paused about 1.0 s in the center.")
    }

    func testSingleMarkWording() {
        let analysis = InkAnalysis(marks: [mark(.scribble, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 90))], dwells: [])
        XCTAssertEqual(GestureSummary.describe(analysis, screenSize: screen),
                       "The user drew 1 mark while speaking: scribbled over the top left.")
    }

    func testShortLineStaysInOneRegion() {
        let analysis = InkAnalysis(marks: [mark(.line, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 110))], dwells: [])
        XCTAssertEqual(GestureSummary.describe(analysis, screenSize: screen),
                       "The user drew 1 mark while speaking: drew a short line in the top left.")
    }

    func testNothingToSayIsNil() {
        XCTAssertNil(GestureSummary.describe(.empty, screenSize: screen))
    }

    func testDwellOnly() {
        let analysis = InkAnalysis(marks: [], dwells: [dwell(at: CGPoint(x: 600, y: 450), seconds: 2.4)])
        XCTAssertEqual(GestureSummary.describe(analysis, screenSize: screen), "The user paused about 2.4 s in the center.")
    }

    func testDwellSecondsAreShownToOneDecimal() {
        let analysis = InkAnalysis(marks: [], dwells: [dwell(at: CGPoint(x: 10, y: 10), seconds: 0.38)])
        XCTAssertEqual(GestureSummary.describe(analysis, screenSize: screen), "The user paused about 0.4 s in the top left.")
    }

    func testOnlyTheTwoLongestDwellsAreListedInTimeOrder() {
        let analysis = InkAnalysis(marks: [], dwells: [
            dwell(at: CGPoint(x: 10, y: 10), seconds: 0.4),
            dwell(at: CGPoint(x: 600, y: 450), seconds: 2.0),
            dwell(at: CGPoint(x: 1100, y: 850), seconds: 1.2)])
        XCTAssertEqual(GestureSummary.describe(analysis, screenSize: screen),
                       "The user paused about 2.0 s in the center; paused about 1.2 s in the bottom right.")
    }

    func testNoCoordinatesAppear() {
        let analysis = InkAnalysis(
            marks: [mark(.circle, from: CGPoint(x: 940, y: 100), to: CGPoint(x: 1060, y: 140))],
            dwells: [dwell(at: CGPoint(x: 733, y: 411), seconds: 1.2)])
        let text = GestureSummary.describe(analysis, screenSize: screen) ?? ""
        for digit in "0123456789" where digit != "1" && digit != "2" && digit != "3" {
            XCTAssertFalse(text.contains(digit), "unexpected digit \(digit) in \(text)")
        }
        XCTAssertFalse(text.contains("733"))
        XCTAssertFalse(text.contains("411"))
    }

    func testIsCappedByListingFewerMarks() {
        let many = (0..<12).map { index in
            mark(.line, from: CGPoint(x: 100, y: 100 + index), to: CGPoint(x: 1100, y: 800))
        }
        let analysis = InkAnalysis(marks: many, dwells: [dwell(at: CGPoint(x: 600, y: 450), seconds: 1)])
        let text = GestureSummary.describe(analysis, screenSize: screen) ?? ""
        XCTAssertLessThanOrEqual(text.count, GestureSummary.characterCap)
        XCTAssertTrue(text.hasPrefix("The user drew 12 marks in order while speaking: 1) "))
        XCTAssertTrue(text.contains("more"))
        XCTAssertTrue(text.hasSuffix("paused about 1.0 s in the center."))
    }

    func testIsDeterministic() {
        let analysis = InkAnalysis(marks: [mark(.circle, from: CGPoint(x: 500, y: 400), to: CGPoint(x: 600, y: 480))],
                                   dwells: [dwell(at: CGPoint(x: 5, y: 5), seconds: 1)])
        XCTAssertEqual(GestureSummary.describe(analysis, screenSize: screen),
                       GestureSummary.describe(analysis, screenSize: screen))
    }

    func testEndToEndFromSamples() {
        // A line across the middle of the screen, a pause, then a circle.
        var samples = InkFixtures.line(from: CGPoint(x: 100, y: 450), to: CGPoint(x: 600, y: 450), wobble: 0)
        samples += InkFixtures.hold(at: CGPoint(x: 600, y: 450), duration: 1.0, startTime: 0.5)
        let afterHold = samples[samples.count - 1].time + 0.02
        samples += InkFixtures.circle(center: CGPoint(x: 600, y: 650), radius: 80, startTime: afterHold)
        let analysis = InkStroke(samples: samples).analyze()
        let text = GestureSummary.describe(analysis, screenSize: screen) ?? ""
        XCTAssertTrue(text.contains("drew a line from the left toward the center"), text)
        XCTAssertTrue(text.contains("paused about 1.0 s in the center"), text)
    }
}

//
//  InkStroke.swift
//  LocalBrainKit
//
//  Pure geometry for the "ink in" feature: while the user holds the gesture
//  keys and glides the mouse, the app records timed samples. This file turns
//  those samples into something the rest of the pipeline can use:
//    - path length, bounding box, Ramer-Douglas-Peucker simplification
//    - jiggle rejection (a twitch is not ink)
//    - dwell detection (a deliberate pause) and splitting the stroke into marks
//      at dwells
//    - classifying each mark as a circle, a line or a scribble
//    - naming screen regions on a 3x3 grid
//
//  All points are display-local, top-left origin, in points (the space the
//  per-screen overlay draws in). Times are seconds on any monotonic clock.
//

import CoreGraphics
import Foundation

public struct InkSample: Equatable, Sendable {
    public var point: CGPoint
    public var time: Double

    public init(point: CGPoint, time: Double) {
        self.point = point
        self.time = time
    }
}

/// A deliberate pause: the pointer stayed inside a small radius for a while.
public struct InkDwell: Equatable, Sendable {
    /// Mean position of the samples inside the pause.
    public let location: CGPoint
    /// Seconds from the first sample of the pause until the pointer left the
    /// radius (or the stroke ended). Counting until the next sample means a
    /// pause shows up even though a stationary mouse emits no events.
    public let duration: Double
    public let startTime: Double
    /// Indices into the stroke's samples that sit inside the pause.
    public let sampleRange: ClosedRange<Int>
}

public enum InkMarkKind: String, Equatable, Sendable {
    case circle
    case line
    case scribble
}

/// One continuous movement between dwells, classified.
public struct InkMark: Equatable, Sendable {
    public let kind: InkMarkKind
    /// The raw samples' points, in order.
    public let points: [CGPoint]
    public let boundingBox: CGRect
    public let pathLength: CGFloat
    public let startTime: Double
    public let endTime: Double

    public var start: CGPoint { points[0] }
    public var end: CGPoint { points[points.count - 1] }
    public var center: CGPoint { CGPoint(x: boundingBox.midX, y: boundingBox.midY) }
}

public struct InkAnalysis: Equatable, Sendable {
    /// In drawing order.
    public let marks: [InkMark]
    /// In time order.
    public let dwells: [InkDwell]

    public var isEmpty: Bool { marks.isEmpty && dwells.isEmpty }
    public static let empty = InkAnalysis(marks: [], dwells: [])
}

/// Point-list helpers, public so the app can reuse them (for example to thin a
/// mark before drawing it).
public enum InkGeometry {
    public static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    public static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        for index in 1..<points.count { total += distance(points[index - 1], points[index]) }
        return total
    }

    /// Nil for an empty list. A single point gives a zero-size rect.
    public static func boundingBox(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Ramer-Douglas-Peucker. Keeps the first and last point; drops points that
    /// sit within `tolerance` of the line between their kept neighbours.
    public static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last - first > 1 else { continue }
            var farthest: CGFloat = -1
            var farthestIndex = first
            for index in (first + 1)..<last {
                let d = distanceFromSegment(points[index], points[first], points[last])
                if d > farthest { farthest = d; farthestIndex = index }
            }
            if farthest > tolerance {
                keep[farthestIndex] = true
                stack.append((first, farthestIndex))
                stack.append((farthestIndex, last))
            }
        }
        return zip(points, keep).filter { $0.1 }.map { $0.0 }
    }

    /// Net signed turning angle in radians along the polyline (counter-clockwise
    /// in a y-up space, clockwise on screen; only the magnitude matters here).
    public static func netTurning(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 2 else { return 0 }
        var total: CGFloat = 0
        var previous: CGVector?
        for index in 1..<points.count {
            let dx = points[index].x - points[index - 1].x
            let dy = points[index].y - points[index - 1].y
            guard dx != 0 || dy != 0 else { continue }
            let current = CGVector(dx: dx, dy: dy)
            if let previous {
                let cross = previous.dx * current.dy - previous.dy * current.dx
                let dot = previous.dx * current.dx + previous.dy * current.dy
                total += atan2(cross, dot)
            }
            previous = current
        }
        return total
    }

    private static func distanceFromSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

public struct InkStroke: Equatable, Sendable {
    public let samples: [InkSample]

    // Thresholds. Public so tests and the app's debug text can refer to them.
    /// A stroke (or a mark) shorter than this is a twitch, not ink.
    public static let minimumPathLength: CGFloat = 30
    /// A pause this long (inside `dwellRadius`) is reported as a dwell, so the
    /// model hears "paused about 0.4 s on the button". Reporting only; a
    /// pause this short does not cut the stroke.
    public static let dwellReportDuration: Double = 0.35
    /// A pause this long (inside `dwellRadius`) also ends one mark and starts
    /// the next. Longer than `dwellReportDuration` on purpose: a brief hover
    /// should not split a circle drawn at a leisurely pace.
    public static let markSplitDuration: Double = 0.6
    public static let dwellRadius: CGFloat = 12
    /// Live trail: nothing is drawn until the pointer is this far (points) from
    /// where the stroke began.
    public static let liveTrailThreshold: CGFloat = 8
    /// Live trail: a new sample closer than this (points) to the last kept one
    /// is dropped. Stationary-mouse ticks add nothing but noise.
    public static let minimumSampleSpacing: CGFloat = 1.5
    /// End-to-start gap, as a fraction of the bounding-box diagonal, under
    /// which a mark counts as closed.
    public static let circleClosureFraction: CGFloat = 0.25
    /// Net turning (radians) a closed mark needs to count as enclosing: 300 degrees.
    public static let circleMinimumTurning: CGFloat = 300 * .pi / 180
    /// Chord over path above which a mark is a line.
    public static let lineStraightness: CGFloat = 0.85

    public init(samples: [InkSample]) {
        self.samples = samples
    }

    public var points: [CGPoint] { samples.map(\.point) }
    public var pathLength: CGFloat { InkGeometry.pathLength(points) }
    public var boundingBox: CGRect? { InkGeometry.boundingBox(points) }
    public var duration: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.time - first.time
    }

    /// True when the whole stroke is under `minimumPathLength`: no ink.
    public var isJiggle: Bool { pathLength < Self.minimumPathLength }

    public func simplified(tolerance: CGFloat) -> [CGPoint] {
        InkGeometry.simplify(points, tolerance: tolerance)
    }

    // MARK: - Dwells

    /// Whether a new live sample is worth keeping: always the first one, and
    /// afterwards only when it is at least `minimumSampleSpacing` from the last
    /// kept one. The closing sample at key up is always kept (`isFinal`), so a
    /// pause at the very end still has an end time.
    public static func shouldKeepSample(_ point: CGPoint, after lastKept: CGPoint?, isFinal: Bool = false) -> Bool {
        guard let lastKept else { return true }
        if isFinal { return true }
        return InkGeometry.distance(point, lastKept) >= minimumSampleSpacing
    }

    /// Pauses of at least `minimumDuration` seconds inside `radius` points of
    /// the pause's first sample. Does not apply jiggle rejection; `analyze()`
    /// does.
    public func dwells(minimumDuration: Double = InkStroke.dwellReportDuration,
                       radius: CGFloat = InkStroke.dwellRadius) -> [InkDwell] {
        var result: [InkDwell] = []
        let count = samples.count
        var index = 0
        while index < count {
            var next = index + 1
            while next < count,
                  InkGeometry.distance(samples[next].point, samples[index].point) <= radius {
                next += 1
            }
            let endTime = next < count ? samples[next].time : samples[count - 1].time
            let duration = endTime - samples[index].time
            if duration >= minimumDuration {
                let window = samples[index..<next].map(\.point)
                let meanX = window.reduce(0) { $0 + $1.x } / CGFloat(window.count)
                let meanY = window.reduce(0) { $0 + $1.y } / CGFloat(window.count)
                result.append(InkDwell(location: CGPoint(x: meanX, y: meanY),
                                       duration: duration,
                                       startTime: samples[index].time,
                                       sampleRange: index...(next - 1)))
                index = next
            } else {
                index += 1
            }
        }
        return result
    }

    // MARK: - Marks

    /// The stroke split at pauses of `markSplitDuration` or more into
    /// classified marks. Empty for a jiggle. A piece shorter than
    /// `minimumPathLength` is dropped.
    public func marks() -> [InkMark] {
        guard !isJiggle else { return [] }
        return marks(splitAt: splitDwells())
    }

    /// Dwells (reported at `dwellReportDuration`) and marks (split at
    /// `markSplitDuration`) together; `.empty` for a jiggle.
    public func analyze() -> InkAnalysis {
        guard !isJiggle else { return .empty }
        return InkAnalysis(marks: marks(splitAt: splitDwells()), dwells: dwells())
    }

    private func splitDwells() -> [InkDwell] {
        dwells(minimumDuration: Self.markSplitDuration)
    }

    private func marks(splitAt dwells: [InkDwell]) -> [InkMark] {
        guard !samples.isEmpty else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var cursor = 0
        for dwell in dwells {
            ranges.append(cursor...dwell.sampleRange.lowerBound)
            cursor = dwell.sampleRange.upperBound
        }
        ranges.append(cursor...(samples.count - 1))

        var result: [InkMark] = []
        for range in ranges {
            let piece = Array(samples[range])
            let piecePoints = piece.map(\.point)
            let length = InkGeometry.pathLength(piecePoints)
            guard length >= Self.minimumPathLength,
                  let box = InkGeometry.boundingBox(piecePoints) else { continue }
            result.append(InkMark(kind: Self.classify(points: piecePoints, pathLength: length, boundingBox: box),
                                  points: piecePoints,
                                  boundingBox: box,
                                  pathLength: length,
                                  startTime: piece[0].time,
                                  endTime: piece[piece.count - 1].time))
        }
        return result
    }

    // MARK: - Classification

    /// Circle: closed (end-to-start gap under 25 percent of the bbox diagonal)
    /// and enclosing (net turning of 300 degrees or more). Line: chord over
    /// path above 0.85. Otherwise scribble. Turning and straightness are
    /// measured on a lightly simplified polyline so hand tremor does not
    /// inflate the path.
    public static func classify(points: [CGPoint], pathLength: CGFloat, boundingBox: CGRect) -> InkMarkKind {
        guard points.count >= 2 else { return .scribble }
        let diagonal = hypot(boundingBox.width, boundingBox.height)
        guard diagonal > 0 else { return .scribble }

        let tolerance = max(2, diagonal * 0.02)
        let simplified = InkGeometry.simplify(points, tolerance: tolerance)
        let gap = InkGeometry.distance(points[0], points[points.count - 1])

        if gap < diagonal * circleClosureFraction,
           abs(InkGeometry.netTurning(simplified)) >= circleMinimumTurning {
            return .circle
        }
        let simplifiedLength = InkGeometry.pathLength(simplified)
        if simplifiedLength > 0, gap / simplifiedLength > lineStraightness {
            return .line
        }
        return .scribble
    }
}

/// The 3x3 grid of the screen used to describe where ink landed.
public enum InkRegion: String, CaseIterable, Equatable, Sendable {
    case topLeft = "top left"
    case top = "top"
    case topRight = "top right"
    case left = "left"
    case center = "center"
    case right = "right"
    case bottomLeft = "bottom left"
    case bottom = "bottom"
    case bottomRight = "bottom right"

    public var name: String { rawValue }

    /// Region of a display-local, top-left-origin point. Points outside the
    /// screen map to the nearest edge cell.
    public static func region(for point: CGPoint, in screenSize: CGSize) -> InkRegion {
        guard screenSize.width > 0, screenSize.height > 0 else { return .center }
        let column = max(0, min(2, Int(floor(point.x / (screenSize.width / 3)))))
        let row = max(0, min(2, Int(floor(point.y / (screenSize.height / 3)))))
        let grid: [[InkRegion]] = [[.topLeft, .top, .topRight],
                                   [.left, .center, .right],
                                   [.bottomLeft, .bottom, .bottomRight]]
        return grid[row][column]
    }

    public static func name(for point: CGPoint, in screenSize: CGSize) -> String {
        region(for: point, in: screenSize).name
    }
}

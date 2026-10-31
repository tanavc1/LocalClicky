//
//  MarkGeometry.swift
//  LocalBrainKit
//
//  The shapes the assistant draws (ink out), as plain points. The overlay view
//  only strokes what this file returns; it makes no geometry decisions.
//
//  Input is a parsed SHAPE or HIGHLIGHT tag mapped into overlay points (the
//  display-local, top-left space of one screen's overlay window). Output is two
//  "passes" of the same figure, the second drawn slightly off the first so the
//  mark reads as a quick double stroke by hand. Each pass is a list of
//  polylines; a closed one is a ring (circle, polygon, highlight box). Curves
//  are sampled finely so the view can draw a plain polyline, trim it for the
//  draw-on animation and dash it.
//
//  The jitter is seeded from the tag itself, so the same tag always gives the
//  same sketch and nothing wobbles from frame to frame.
//

import CoreGraphics
import Foundation

/// One polyline of a mark. A closed polyline joins its last point to its first.
public struct MarkSubpath: Equatable, Sendable {
    public var points: [CGPoint]
    public var isClosed: Bool

    public init(points: [CGPoint], isClosed: Bool) {
        self.points = points
        self.isClosed = isClosed
    }
}

/// A mark ready to draw: `passes.count` strokes of the same figure.
public struct MarkGeometry: Equatable, Sendable {
    public var passes: [[MarkSubpath]]

    public init(passes: [[MarkSubpath]]) {
        self.passes = passes
    }
}

/// A SHAPE or HIGHLIGHT tag in overlay points.
public enum OverlayDrawing: Equatable, Sendable {
    case shape(kind: ShapeKind, points: [CGPoint])
    case highlight(rect: CGRect)
}

public enum MarkGeometryBuilder {
    /// Two strokes per mark.
    public static let passCount = 2
    /// The second stroke is never more than this far (points) from the first.
    public static let maxPassOffset: Double = 1.5
    /// Spacing of the sampled points along a line or edge, in points.
    public static let sampleSpacing: Double = 10
    /// A circle whose ring point sits on its centre still gets this radius.
    public static let minimumCircleRadius: Double = 6
    public static let curveSamplesPerSegment = 12
    public static let arrowheadAngleDegrees: Double = 28
    public static let highlightCornerRadius: Double = 8

    // MARK: - From a tag to overlay points

    /// Maps a parsed tag from screenshot pixels into this display's overlay
    /// points. Points outside the screenshot are clamped onto its edge, the same
    /// as the pointing cursor.
    public static func overlayDrawing(from drawing: InkDrawing, mapping: ScreenMapping) -> OverlayDrawing {
        switch drawing {
        case .shape(let tag):
            return .shape(kind: tag.kind, points: tag.points.map { mapping.overlayPoint(forImagePoint: $0) })
        case .highlight(let tag):
            let corner1 = mapping.overlayPoint(forImagePoint: CGPoint(x: tag.rect.minX, y: tag.rect.minY))
            let corner2 = mapping.overlayPoint(forImagePoint: CGPoint(x: tag.rect.maxX, y: tag.rect.maxY))
            return .highlight(rect: CGRect(x: min(corner1.x, corner2.x), y: min(corner1.y, corner2.y),
                                           width: abs(corner2.x - corner1.x), height: abs(corner2.y - corner1.y)))
        }
    }

    // MARK: - The full figure

    /// The two jittered passes for a drawing. Deterministic for the same input.
    public static func geometry(for drawing: OverlayDrawing) -> MarkGeometry {
        let base = baseSubpaths(for: drawing)
        let seed = seed(for: drawing)
        // Pass 1 stays within 0.5 pt of the clean figure and pass 2 within 1.0
        // pt, so the second stroke is at most 1.5 pt from the first.
        let first = jitter(base, seed: seed, maxOffset: maxPassOffset / 3)
        let second = jitter(base, seed: seed ^ 0x9E37_79B9_7F4A_7C15, maxOffset: maxPassOffset * 2 / 3)
        return MarkGeometry(passes: [first, second])
    }

    /// The clean figure before jitter: one or more polylines.
    public static func baseSubpaths(for drawing: OverlayDrawing) -> [MarkSubpath] {
        switch drawing {
        case .shape(let kind, let points):
            switch kind {
            case .line:
                guard points.count == 2 else { return [] }
                return [MarkSubpath(points: sampledLine(from: points[0], to: points[1]), isClosed: false)]
            case .arrow:
                guard points.count == 2 else { return [] }
                let head = arrowhead(tail: points[0], tip: points[1])
                return [MarkSubpath(points: sampledLine(from: points[0], to: points[1]), isClosed: false),
                        MarkSubpath(points: head, isClosed: false)]
            case .circle:
                guard points.count == 2 else { return [] }
                return [MarkSubpath(points: circlePoints(centre: points[0], ringPoint: points[1]), isClosed: true)]
            case .curve:
                guard points.count >= 2 else { return [] }
                return [MarkSubpath(points: catmullRom(points, samplesPerSegment: curveSamplesPerSegment), isClosed: false)]
            case .polygon:
                guard points.count >= 3 else { return [] }
                return [MarkSubpath(points: polygonPoints(points), isClosed: true)]
            }
        case .highlight(let rect):
            guard rect.width > 0, rect.height > 0 else { return [] }
            return [MarkSubpath(points: roundedRectPoints(rect, radius: highlightCornerRadius), isClosed: true)]
        }
    }

    // MARK: - Primitives

    /// A straight stroke sampled about every `sampleSpacing` points, with at
    /// least two segments so the jitter has something to bend.
    public static func sampledLine(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let length = Double(InkGeometry.distance(start, end))
        let segments = max(2, Int((length / sampleSpacing).rounded()))
        return (0...segments).map { index in
            let t = CGFloat(index) / CGFloat(segments)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }

    /// A ring around `centre` through `ringPoint`, as a closed list of points
    /// (the last point is not a repeat of the first). Starts at the ring point.
    public static func circlePoints(centre: CGPoint, ringPoint: CGPoint) -> [CGPoint] {
        let radius = max(minimumCircleRadius, Double(InkGeometry.distance(centre, ringPoint)))
        let startAngle = atan2(Double(ringPoint.y - centre.y), Double(ringPoint.x - centre.x))
        let circumference = 2 * Double.pi * radius
        let count = max(24, min(72, Int((circumference / sampleSpacing).rounded())))
        return (0..<count).map { index in
            let angle = startAngle + 2 * Double.pi * Double(index) / Double(count)
            return CGPoint(x: Double(centre.x) + radius * cos(angle), y: Double(centre.y) + radius * sin(angle))
        }
    }

    /// A uniform Catmull-Rom spline through every input point: it starts at the
    /// first point, ends at the last and passes through each one between. Fewer
    /// than 3 points come back as given.
    public static func catmullRom(_ points: [CGPoint], samplesPerSegment: Int) -> [CGPoint] {
        guard points.count >= 3, samplesPerSegment > 0 else { return points }
        // Duplicate the ends so the first and last segments have neighbours.
        let padded = [points[0]] + points + [points[points.count - 1]]
        var output: [CGPoint] = [points[0]]
        for index in 1..<(padded.count - 2) {
            let p0 = padded[index - 1], p1 = padded[index], p2 = padded[index + 1], p3 = padded[index + 2]
            for step in 1...samplesPerSegment {
                let t = CGFloat(step) / CGFloat(samplesPerSegment)
                let t2 = t * t, t3 = t2 * t
                func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                output.append(CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        return output
    }

    /// The two barbs and the tip of an arrowhead, as one polyline (barb, tip,
    /// barb). The barbs trail back along the shaft from the tip. The head is
    /// a quarter of the shaft, between 10 and 24 points long.
    public static func arrowhead(tail: CGPoint, tip: CGPoint) -> [CGPoint] {
        let length = Double(InkGeometry.distance(tail, tip))
        guard length > 0 else { return [tip, tip, tip] }
        let headLength = min(24, max(10, length * 0.25))
        // Direction from the tip back toward the tail.
        let back = atan2(Double(tail.y - tip.y), Double(tail.x - tip.x))
        let spread = arrowheadAngleDegrees * Double.pi / 180
        func barb(_ angle: Double) -> CGPoint {
            CGPoint(x: Double(tip.x) + headLength * cos(angle), y: Double(tip.y) + headLength * sin(angle))
        }
        return [barb(back + spread), tip, barb(back - spread)]
    }

    /// A closed polygon with each edge sampled.
    public static func polygonPoints(_ corners: [CGPoint]) -> [CGPoint] {
        var output: [CGPoint] = []
        for index in corners.indices {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]
            // Drop the edge's last point: it is the next edge's first.
            output.append(contentsOf: sampledLine(from: start, to: end).dropLast())
        }
        return output
    }

    /// A closed rounded rectangle, starting at the top edge, clockwise on
    /// screen (y down). Corner arcs have 6 samples each; edges follow
    /// `sampleSpacing`.
    public static func roundedRectPoints(_ rect: CGRect, radius: Double) -> [CGPoint] {
        let corner = CGFloat(max(0, min(radius, Double(min(rect.width, rect.height)) / 2)))
        let arcSamples = 6
        // Corner centres, with the angle each arc starts at (y down: 0 is
        // right, 90 degrees is down).
        let arcs: [(centre: CGPoint, start: Double)] = [
            (CGPoint(x: rect.maxX - corner, y: rect.minY + corner), -90),
            (CGPoint(x: rect.maxX - corner, y: rect.maxY - corner), 0),
            (CGPoint(x: rect.minX + corner, y: rect.maxY - corner), 90),
            (CGPoint(x: rect.minX + corner, y: rect.minY + corner), 180),
        ]
        var output: [CGPoint] = []
        for arc in arcs {
            // The straight edge that leads into this corner starts where the
            // previous arc ended; sample it from there.
            let arcStart = arcPoint(arc.centre, corner, arc.start)
            if let last = output.last {
                output.append(contentsOf: sampledLine(from: last, to: arcStart).dropFirst().dropLast())
            }
            for step in 0...arcSamples {
                let angle = arc.start + 90 * Double(step) / Double(arcSamples)
                output.append(arcPoint(arc.centre, corner, angle))
            }
        }
        // The edge from the last arc back to the first.
        if let last = output.last, let first = output.first {
            output.append(contentsOf: sampledLine(from: last, to: first).dropFirst().dropLast())
        }
        return output
    }

    private static func arcPoint(_ centre: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
        let angle = degrees * Double.pi / 180
        return CGPoint(x: centre.x + radius * CGFloat(cos(angle)), y: centre.y + radius * CGFloat(sin(angle)))
    }

    // MARK: - Jitter

    /// Moves every point by a pseudo-random offset of at most `maxOffset`
    /// points, the same offsets for the same seed.
    public static func jitter(_ points: [CGPoint], seed: UInt64, maxOffset: Double) -> [CGPoint] {
        var generator = SeededGenerator(seed: seed)
        return points.map { moved($0, by: &generator, maxOffset: maxOffset) }
    }

    private static func jitter(_ subpaths: [MarkSubpath], seed: UInt64, maxOffset: Double) -> [MarkSubpath] {
        // One generator across the figure's subpaths, so each gets different noise.
        var generator = SeededGenerator(seed: seed)
        return subpaths.map { subpath in
            MarkSubpath(points: subpath.points.map { moved($0, by: &generator, maxOffset: maxOffset) },
                        isClosed: subpath.isClosed)
        }
    }

    private static func moved(_ point: CGPoint, by generator: inout SeededGenerator, maxOffset: Double) -> CGPoint {
        let angle = generator.nextUnit() * 2 * Double.pi
        let distance = generator.nextUnit() * maxOffset
        return CGPoint(x: Double(point.x) + cos(angle) * distance, y: Double(point.y) + sin(angle) * distance)
    }

    /// A stable seed from the figure itself (FNV-1a over its kind and its
    /// coordinates rounded to tenths of a point).
    public static func seed(for drawing: OverlayDrawing) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ value: Int64) {
            var bits = UInt64(bitPattern: value)
            for _ in 0..<8 {
                hash = (hash ^ (bits & 0xFF)) &* 0x0000_0100_0000_01B3
                bits >>= 8
            }
        }
        func mixTenths(_ value: Double) { mix(Int64((value * 10).rounded())) }
        switch drawing {
        case .shape(let kind, let points):
            mix(Int64(ShapeKind.allCases.firstIndex(of: kind) ?? 0))
            for point in points { mixTenths(Double(point.x)); mixTenths(Double(point.y)) }
        case .highlight(let rect):
            mix(Int64(100))
            mixTenths(Double(rect.minX)); mixTenths(Double(rect.minY)); mixTenths(Double(rect.width)); mixTenths(Double(rect.height))
        }
        return hash
    }

    /// SplitMix64: tiny, deterministic, good enough for visual noise.
    private struct SeededGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// A value in 0..<1.
        mutating func nextUnit() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }
    }
}

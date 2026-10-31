//
//  PointThenDraw.swift
//  LocalBrainKit
//
//  Circle and arrow requests ("circle the save button", "draw an arrow to the
//  gear") are drawn by the app from a point, not by the model from a shape tag.
//
//  Why: asked for `[SHAPE:circle:cx,cy;ex,ey:label]` the 9B misread the second
//  pair as radii (39 of 90 eval rows) and located the target worse than it does
//  when it only points (centre in box 0.36 against 0.67). So the grounding
//  model is asked for what it does well, one `[POINT:x,y:label]` (the point
//  route prompt), and this file builds the ring or arrow around that point.
//
//  Everything here is in screenshot pixels except the optional control frame,
//  which is in display-local points (top-left origin, the overlay's space). The
//  app gets that frame from the Accessibility element under the point and
//  converts it with ScreenMapping.displayLocalRect(forCGGlobalRect:...).
//
//  The old route, where the model writes the tag itself, still serves line,
//  curve, polygon and highlight requests, and serves circle and arrow too when
//  the flag below is set, so the eval can compare the two.
//

import CoreGraphics
import Foundation

/// A mark the app can build from a point.
public enum PointDrawKind: Equatable, Sendable {
    case circle
    case arrow
}

/// A mark built in code, with the one sentence that says what it marks.
public struct PointDrawPlan: Equatable, Sendable {
    public let drawing: InkDrawing
    /// Spoken with the mark, because the mark is visual only.
    public let spokenSentence: String
}

public enum PointThenDraw {
    // MARK: - The flag

    /// UserDefaults key. Set it to true to send circle and arrow requests down
    /// the old route (the model writes the SHAPE tag), for the eval's
    /// comparison: `defaults write <bundle id> drawCircleArrowWithModelShapeTags -bool YES`.
    public static let modelShapeTagFlagKey = "drawCircleArrowWithModelShapeTags"

    /// True (the default) when circle and arrow requests are drawn from a point.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: modelShapeTagFlagKey)
    }

    // MARK: - Constants

    /// Ring radius, in screenshot pixels, when there is no usable control
    /// frame. PLACEHOLDER: the eval sets this from DEV (a fixed 24 to 36 px ring
    /// scored 0.72 to 0.86 on the 9B's DEV points). The screenshot is 1152 px
    /// wide, so its size on screen follows the capture scale: 30 px is about 67
    /// points on a 2560 pt display and about 40 points on a 1512 pt one.
    public static let defaultRingRadiusInImagePixels: Double = 30

    /// A control frame larger than this (points) is a container, not the one
    /// control the point is on, and is not used.
    public static let maxControlFrameInPoints = CGSize(width: 300, height: 120)

    /// The ring clears the control: radius = half the frame's diagonal x this.
    public static let controlRingMargin: Double = 1.15

    /// Arrow length, in screenshot pixels, from tail to tip. PLACEHOLDER: the
    /// eval sets this from DEV.
    public static let arrowTailOffsetInImagePixels: Double = 90

    // MARK: - Building

    /// The mark for a point. `controlFrameInDisplayPoints` is the Accessibility
    /// frame of the element at the point, or nil when none was read.
    public static func plan(kind: PointDrawKind,
                            pointInImagePixels point: CGPoint,
                            label: String?,
                            controlFrameInDisplayPoints: CGRect?,
                            mapping: ScreenMapping) -> PointDrawPlan {
        let width = Double(mapping.screenshotWidthInPixels)
        let height = Double(mapping.screenshotHeightInPixels)
        let centre = CGPoint(x: min(max(point.x, 0), width), y: min(max(point.y, 0), height))
        let frame = usableFrameInImagePixels(controlFrameInDisplayPoints, around: centre, mapping: mapping)
        let cleanLabel = cleanedLabel(label)

        let points: [CGPoint]
        switch kind {
        case .circle:
            let radius = frame.map { 0.5 * hypot($0.width, $0.height) * controlRingMargin }
                ?? defaultRingRadiusInImagePixels
            // With a control frame the ring is centred on the frame (the model's
            // point is a noisy estimate, the frame is exact); without one, on the point.
            let ringCentre = frame.map { CGPoint(x: min(max($0.midX, 0), width), y: min(max($0.midY, 0), height)) } ?? centre
            // The ring point sits directly right of the centre (the tag grammar),
            // or left of it when the ring would run off the screenshot.
            let ringX = ringCentre.x + radius <= width ? ringCentre.x + radius : ringCentre.x - radius
            points = [ringCentre, CGPoint(x: ringX, y: ringCentre.y)]
        case .arrow:
            points = arrowPoints(tipTarget: centre, frame: frame, width: width, height: height)
        }
        let shape = ShapeTag(kind: kind == .circle ? .circle : .arrow, points: points,
                             label: cleanLabel, screenNumber: nil)
        return PointDrawPlan(drawing: .shape(shape), spokenSentence: spokenSentence(kind: kind, label: cleanLabel))
    }

    /// The frame in screenshot pixels, or nil when it should not be used: empty,
    /// bigger than one control, or not under the point.
    static func usableFrameInImagePixels(_ frame: CGRect?, around point: CGPoint, mapping: ScreenMapping) -> CGRect? {
        guard let frame, frame.width > 0, frame.height > 0,
              frame.width <= maxControlFrameInPoints.width, frame.height <= maxControlFrameInPoints.height else { return nil }
        let pixelsPerPointX = Double(mapping.screenshotWidthInPixels) / Double(mapping.displayWidthInPoints)
        let pixelsPerPointY = Double(mapping.screenshotHeightInPixels) / Double(mapping.displayHeightInPoints)
        let inPixels = CGRect(x: frame.minX * pixelsPerPointX, y: frame.minY * pixelsPerPointY,
                              width: frame.width * pixelsPerPointX, height: frame.height * pixelsPerPointY)
        return inPixels.contains(point) ? inPixels : nil
    }

    /// Tip and tail. The tail is `arrowTailOffsetInImagePixels` away, on the side
    /// of the point with the most room on the display (ties go left, right, above,
    /// below). With a frame, the tip is the frame's edge on that side.
    static func arrowPoints(tipTarget point: CGPoint, frame: CGRect?, width: Double, height: Double) -> [CGPoint] {
        let sides: [(room: Double, direction: CGVector)] = [
            (point.x, CGVector(dx: -1, dy: 0)),
            (width - point.x, CGVector(dx: 1, dy: 0)),
            (point.y, CGVector(dx: 0, dy: -1)),
            (height - point.y, CGVector(dx: 0, dy: 1)),
        ]
        var best = sides[0]
        for side in sides.dropFirst() where side.room > best.room { best = side }
        let direction = best.direction

        var tip = point
        if let frame {
            if direction.dx < 0 { tip.x = frame.minX } else if direction.dx > 0 { tip.x = frame.maxX }
            if direction.dy < 0 { tip.y = frame.minY } else if direction.dy > 0 { tip.y = frame.maxY }
        }
        let tail = CGPoint(x: min(max(tip.x + direction.dx * arrowTailOffsetInImagePixels, 0), width),
                           y: min(max(tip.y + direction.dy * arrowTailOffsetInImagePixels, 0), height))
        return [tail, tip]
    }

    // MARK: - Words

    /// The point reply's label without "none", whitespace or a leading "the ".
    static func cleanedLabel(_ label: String?) -> String? {
        guard var text = label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !text.isEmpty, text != "none" else { return nil }
        if text.hasPrefix("the ") { text = String(text.dropFirst(4)) }
        return text.isEmpty ? nil : text
    }

    /// One short sentence saying what the mark is on, for someone who cannot see it.
    public static func spokenSentence(kind: PointDrawKind, label: String?) -> String {
        let marked = kind == .circle ? "circled" : "marked with an arrow"
        guard let name = cleanedLabel(label) else { return "here it is, \(marked)." }
        return "that is the \(name), \(marked)."
    }
}

extension DrawingIntent {
    /// Which mark to build from a point, or nil when the request is for another
    /// kind of mark (underline, highlight, outline, box, line...) or asks for
    /// both, so the model's own shape tag serves it. A bare "mark this", "draw
    /// it" or "show me where" defaults to a circle. Nil too when point-then-draw
    /// is switched off.
    public static func pointThenDrawKind(_ transcript: String, pointThenDrawEnabled: Bool) -> PointDrawKind? {
        guard pointThenDrawEnabled, wantsDrawing(transcript) else { return nil }
        let text = transcript.lowercased()
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

        if matches(#"\b(?:underline|highlight|outline|box|rectangle|square|border|lines?|polygon|curve|squiggle|zigzag)\b"#) { return nil }
        let wantsCircle = matches(#"\b(?:circle|circled|circling|ring)\b"#)
        // "circle the undo arrow" circles; the arrow there is the thing, not the mark.
        let wantsArrow = matches(#"\b(?:draw|add|put|make|give|use)\b[^.]*?\barrows?\b"#)
            || matches(#"\barrows?\s+(?:to|at|toward|towards|pointing|on)\b"#)
        if wantsCircle && wantsArrow { return nil }
        return wantsArrow ? .arrow : .circle
    }
}

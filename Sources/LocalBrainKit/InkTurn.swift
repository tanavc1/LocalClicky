//
//  InkTurn.swift
//  LocalBrainKit
//
//  Everything the turn needs from the user's ink at key up, as pure steps on
//  top of ScreenMapping, InkStroke, GestureSummary and InkImage:
//    analyze: global samples on the captured display, analysed, worded, and
//             mapped to screenshot pixels, with the points to probe for
//             Accessibility;
//    render:  the stroke composited onto the press-time JPEG, and the close-up
//             cut around it from the clean capture, so the ink never hides
//             the target in the close-up.
//  `analyze` is cheap. `render` decodes and encodes JPEGs, so the app runs it
//  off the main thread.
//

import CoreGraphics
import Foundation

public struct InkTurnAnalysis: Equatable, Sendable {
    public let analysis: InkAnalysis
    /// One sentence in plain words, no coordinates.
    public let gestureSummary: String
    public var markCount: Int { analysis.marks.count }
    /// The kind of the mark when there is exactly one; nil for none (pauses
    /// only) or several, where the mark line has no single answer.
    public var singleMarkKind: InkMarkKind? { analysis.marks.count == 1 ? analysis.marks[0].kind : nil }
    /// Mark points in screenshot pixels, ready to composite. A stroke that is
    /// only pauses has one single-point stroke per pause.
    public let strokesInImagePixels: [[CGPoint]]
    /// The ink's bounding box in screenshot pixels.
    public let boundsInImagePixels: CGRect
    /// Where to hit-test for Accessibility, in display-local points.
    public let probePointsInDisplayPoints: [CGPoint]
}

public struct InkTurnImages: Equatable, Sendable {
    public let compositedJPEG: Data
    public let cropJPEG: Data?
}

public enum InkTurn {
    /// Nil when there is no usable ink on this display: no samples here, a
    /// jiggle, or nothing left after analysis. Samples on other displays are
    /// ignored.
    public static func analyze(globalSamples: [InkSample], mapping: ScreenMapping) -> InkTurnAnalysis? {
        let local = globalSamples
            .filter { mapping.containsGlobalPoint($0.point) }
            .map { InkSample(point: mapping.displayLocalPoint(forGlobalPoint: $0.point), time: $0.time) }
        guard !local.isEmpty else { return nil }

        let analysis = InkStroke(samples: local).analyze()
        guard !analysis.isEmpty,
              let summary = GestureSummary.describe(analysis, screenSize: mapping.displaySizeInPoints),
              let bounds = InkAccessibilityGrid.bounds(of: analysis) else { return nil }

        func toImage(_ point: CGPoint) -> CGPoint { mapping.imagePoint(forOverlayPoint: point) }
        let strokes: [[CGPoint]] = analysis.marks.isEmpty
            ? analysis.dwells.map { [toImage($0.location)] }
            : analysis.marks.map { $0.points.map(toImage) }

        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY)].map(toImage)
        let imageBounds = CGRect(x: corners[0].x, y: corners[0].y,
                                 width: corners[1].x - corners[0].x, height: corners[1].y - corners[0].y)

        return InkTurnAnalysis(analysis: analysis,
                               gestureSummary: summary,
                               strokesInImagePixels: strokes,
                               boundsInImagePixels: imageBounds,
                               probePointsInDisplayPoints: InkAccessibilityGrid.probePoints(for: analysis))
    }

    /// The thinnest core, in screenshot pixels, the model's copy of the ink may
    /// have. On an external display the screenshot is scaled by about 0.45, so
    /// the 4 pt core is 1.8 px there and the 9B cannot see a thin underline
    /// (0 of 15 external-scale rows hit). The on-screen ink does not change.
    public static let minimumCoreWidthInImagePixels: Double = 3

    /// The composited screenshot and the close-up. Nil if the JPEG cannot be
    /// decoded or encoded. The crop is nil only when it alone fails.
    ///
    /// The composite is the model's copy of the ink, so its core is widened to
    /// `minimumCoreWidthInImagePixels` (casings scale with it). The close-up is
    /// cut from the clean `jpegData`, not from the composite: a scribble over
    /// the target would otherwise hide it in both images.
    public static func render(jpegData: Data, analysis: InkTurnAnalysis, style: InkStyle) -> InkTurnImages? {
        guard let composited = InkImage.compositeInk(jpegData: jpegData,
                                                     strokesInImagePixels: analysis.strokesInImagePixels,
                                                     style: style.withMinimumCoreWidth(minimumCoreWidthInImagePixels)) else { return nil }
        let crop = InkImage.cropAround(jpegData: jpegData, rectInImagePixels: analysis.boundsInImagePixels)
        return InkTurnImages(compositedJPEG: composited, cropJPEG: crop?.jpegData)
    }
}

//
//  InkAccessibilityGrid.swift
//  LocalBrainKit
//
//  The geometry half of the Accessibility harvest: which points of the marked
//  area to probe. The app hit-tests each point with the system Accessibility
//  API and hands the records to AccessibilitySummary. Everything here is in
//  display-local points (top-left origin), the space InkAnalysis uses.
//

import CoreGraphics
import Foundation

public enum InkAccessibilityGrid {
    public static let columns = 6
    public static let rows = 6
    /// A pause with no stroke around it is probed as a box this far to each side.
    public static let dwellHalfExtent: CGFloat = 24

    /// The area the ink covers: the union of the marks' boxes, or, when the
    /// stroke is only pauses, a small box around each pause. Nil when empty.
    public static func bounds(of analysis: InkAnalysis) -> CGRect? {
        var boxes = analysis.marks.map(\.boundingBox)
        if boxes.isEmpty {
            boxes = analysis.dwells.map {
                CGRect(x: $0.location.x - dwellHalfExtent, y: $0.location.y - dwellHalfExtent,
                       width: dwellHalfExtent * 2, height: dwellHalfExtent * 2)
            }
        }
        guard var union = boxes.first else { return nil }
        for box in boxes.dropFirst() { union = union.union(box) }
        return union
    }

    /// Cell centres of a `columns` x `rows` grid across `bounds` (row by row),
    /// followed by `extraPoints`, with exact duplicates removed in order (a
    /// degenerate box would otherwise repeat one point).
    public static func probePoints(in bounds: CGRect,
                                   extraPoints: [CGPoint] = [],
                                   columns: Int = InkAccessibilityGrid.columns,
                                   rows: Int = InkAccessibilityGrid.rows) -> [CGPoint] {
        guard columns > 0, rows > 0 else { return extraPoints }
        var points: [CGPoint] = []
        for row in 0..<rows {
            for column in 0..<columns {
                points.append(CGPoint(x: bounds.minX + bounds.width * (CGFloat(column) + 0.5) / CGFloat(columns),
                                      y: bounds.minY + bounds.height * (CGFloat(row) + 0.5) / CGFloat(rows)))
            }
        }
        points.append(contentsOf: extraPoints)
        var seen = Set<[CGFloat]>()
        return points.filter { seen.insert([$0.x, $0.y]).inserted }
    }

    /// The grid across the ink's bounds plus each mark's centre and each pause.
    public static func probePoints(for analysis: InkAnalysis) -> [CGPoint] {
        guard let area = bounds(of: analysis) else { return [] }
        let extras = analysis.marks.map(\.center) + analysis.dwells.map(\.location)
        return probePoints(in: area, extraPoints: extras)
    }
}

//
//  ShapeTag.swift
//  LocalBrainKit
//
//  The "ink out" tags the model emits so the overlay can draw while the answer
//  is spoken:
//    [SHAPE:kind:x,y;x,y;...:label(:screenN)]   kind: line|arrow|circle|curve|polygon
//    [HIGHLIGHT:x1,y1,x2,y2(:label)(:screenN)]
//  Coordinates are screenshot pixels (top-left origin), the same space as
//  [POINT] tags. A complete tag that does not validate is dropped, never
//  guessed at, and never spoken: every complete SHAPE, HIGHLIGHT and POINT tag
//  is stripped from the returned text.
//
//  Point counts: line and arrow have exactly 2 points; circle has 2 (centre,
//  then a point on the ring); curve and polygon have 3 to 16.
//

import CoreGraphics
import Foundation

public enum ShapeKind: String, Equatable, Sendable, CaseIterable {
    case line, arrow, circle, curve, polygon
}

public struct ShapeTag: Equatable, Sendable {
    public let kind: ShapeKind
    public let points: [CGPoint]
    public let label: String?
    /// 1-based monitor number if the model targeted a specific screen.
    public let screenNumber: Int?
}

public struct HighlightTag: Equatable, Sendable {
    /// Normalised so width and height are positive.
    public let rect: CGRect
    public let label: String?
    public let screenNumber: Int?
}

/// One drawing instruction, in the order the model emitted it.
public enum InkDrawing: Equatable, Sendable {
    case shape(ShapeTag)
    case highlight(HighlightTag)
}

public struct ShapeTagParseResult: Equatable, Sendable {
    /// Valid shapes and highlights in text order.
    public let drawings: [InkDrawing]
    /// The text with every SHAPE, HIGHLIGHT and POINT tag removed, trimmed.
    public let spokenText: String

    public var shapes: [ShapeTag] {
        drawings.compactMap { if case .shape(let shape) = $0 { return shape } else { return nil } }
    }
    public var highlights: [HighlightTag] {
        drawings.compactMap { if case .highlight(let highlight) = $0 { return highlight } else { return nil } }
    }
}

public enum ShapeTagParser {
    /// Any complete SHAPE or HIGHLIGHT tag. A tag cannot contain another "[".
    static let drawingTagPattern = #"\[(?:SHAPE|HIGHLIGHT)\b[^\[\]]*\]"#
    /// Any complete SHAPE, HIGHLIGHT or POINT tag.
    static let anyTagPattern = #"\[(?:SHAPE|HIGHLIGHT|POINT)\b[^\[\]]*\]"#

    static let drawingRegex = try! NSRegularExpression(pattern: drawingTagPattern, options: [.caseInsensitive])
    private static let anyRegex = try! NSRegularExpression(pattern: anyTagPattern, options: [.caseInsensitive])

    public static let maxCurvePoints = 16

    // MARK: - Parse

    public static func parse(from text: String) -> ShapeTagParseResult {
        let range = NSRange(text.startIndex..., in: text)
        let drawings: [InkDrawing] = drawingRegex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { parseTag(String(text[$0])) }
        }
        return ShapeTagParseResult(drawings: drawings, spokenText: stripAllTags(from: text))
    }

    /// Parses one complete tag including its brackets. Nil when it is not a
    /// valid SHAPE or HIGHLIGHT tag.
    public static func parseTag(_ tag: String) -> InkDrawing? {
        guard tag.hasPrefix("["), tag.hasSuffix("]") else { return nil }
        let inner = String(tag.dropFirst().dropLast())
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyword = parts.first?.uppercased() else { return nil }
        switch keyword {
        case "SHAPE": return parseShape(Array(parts.dropFirst()))
        case "HIGHLIGHT": return parseHighlight(Array(parts.dropFirst()))
        default: return nil
        }
    }

    // MARK: - Strip

    /// Removes every complete SHAPE, HIGHLIGHT and POINT tag.
    public static func stripAllTags(from text: String) -> String {
        strip(text, using: anyRegex)
    }

    /// Removes only complete SHAPE and HIGHLIGHT tags (POINT is left for
    /// PointingTagParser, which parses it).
    public static func stripDrawingTags(from text: String) -> String {
        strip(text, using: drawingRegex)
    }

    /// Removes the tags, and drops the whitespace that followed a tag when the
    /// text before it already ends in whitespace (or is empty), so no double
    /// spaces are left behind. Trims the result.
    private static func strip(_ text: String, using regex: NSRegularExpression) -> String {
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var output = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            output += text[cursor..<range.lowerBound]
            cursor = range.upperBound
            if output.isEmpty || output.last?.isWhitespace == true {
                while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            }
        }
        output += text[cursor...]
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SHAPE

    private static func parseShape(_ parts: [String]) -> InkDrawing? {
        // parts: kind, points, then optional label and optional screenN.
        guard parts.count >= 2, let kind = ShapeKind(rawValue: parts[0].lowercased()),
              let points = parsePoints(parts[1]) else { return nil }
        switch kind {
        case .line, .arrow, .circle:
            guard points.count == 2 else { return nil }
        case .curve, .polygon:
            guard (3...maxCurvePoints).contains(points.count) else { return nil }
        }
        guard let tail = parseTail(Array(parts.dropFirst(2))) else { return nil }
        return .shape(ShapeTag(kind: kind, points: points, label: tail.label, screenNumber: tail.screen))
    }

    /// "x,y;x,y;..." into points. Nil on any malformed point.
    private static func parsePoints(_ text: String) -> [CGPoint]? {
        let chunks = text.split(separator: ";", omittingEmptySubsequences: false)
        var points: [CGPoint] = []
        for chunk in chunks {
            let numbers = chunk.split(separator: ",", omittingEmptySubsequences: false)
                .map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 2, let x = numbers[0], let y = numbers[1], x.isFinite, y.isFinite else { return nil }
            points.append(CGPoint(x: x, y: y))
        }
        return points.isEmpty ? nil : points
    }

    /// The optional trailing "label" and "screenN" parts. A part that is
    /// exactly screenN is the screen, otherwise the first one is the label.
    /// Nil when there are too many parts or a second label.
    private static func parseTail(_ parts: [String]) -> (label: String?, screen: Int?)? {
        var label: String?
        var screen: Int?
        for part in parts {
            if let number = screenNumber(in: part) {
                guard screen == nil else { return nil }
                screen = number
            } else if !part.isEmpty {
                guard label == nil else { return nil }
                label = part
            }
        }
        return (label, screen)
    }

    private static func screenNumber(in part: String) -> Int? {
        guard part.range(of: #"^(?i)screen\s*\d+$"#, options: .regularExpression) != nil,
              let digits = part.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(part[digits])
    }

    // MARK: - HIGHLIGHT

    private static func parseHighlight(_ parts: [String]) -> InkDrawing? {
        guard let first = parts.first else { return nil }
        let numbers = first.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4,
              let x1 = numbers[0], let y1 = numbers[1], let x2 = numbers[2], let y2 = numbers[3],
              [x1, y1, x2, y2].allSatisfy({ $0.isFinite }) else { return nil }
        let rect = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        // A highlight with no area highlights nothing.
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard let tail = parseTail(Array(parts.dropFirst())) else { return nil }
        return .highlight(HighlightTag(rect: rect, label: tail.label, screenNumber: tail.screen))
    }
}

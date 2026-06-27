//
//  PointingTag.swift
//  LocalBrainKit
//
//  Parses the pointing tag the vision model appends to a screen answer so the
//  blue cursor knows where to fly. The original Clicky used Claude's
//  `[POINT:x,y:label:screenN]`; local vision models (Qwen2.5-VL) like to emit a
//  bounding box `[x1,y1,x2,y2:label]` instead. This parser accepts both — and a
//  bare box with no POINT: prefix — and always reduces to a single center point
//  in the screenshot's pixel coordinate space, which is exactly what the cursor
//  overlay's coordinate mapping expects.
//

import CoreGraphics
import Foundation

public struct PointingTag: Equatable, Sendable {
    /// The response with the pointing tag(s) removed — this is what gets spoken.
    public let spokenText: String
    /// Center of the target in screenshot pixel coordinates (top-left origin),
    /// or nil when the model said "none" or emitted no tag.
    public let centerInImagePixels: CGPoint?
    /// The raw bounding box if the model gave one (lets a caller snap/refine).
    public let boundingBoxInImagePixels: CGRect?
    /// Short element description (e.g. "save button"), or nil.
    public let label: String?
    /// 1-based monitor number if the model targeted a specific screen.
    public let screenNumber: Int?

    public var hasPoint: Bool { centerInImagePixels != nil }
}

public enum PointingTagParser {
    /// Parses (and strips) the pointing tag from a model response.
    public static func parse(from response: String) -> PointingTag {
        // 1) Prefer an explicit [POINT:...] tag (what we prompt the model for).
        if let tag = parsePointTag(in: response) { return tag }
        // 2) Fall back to a bare bracket box/point like "[932,415,978,436:REC]"
        //    that vision models emit when they ignore the requested format.
        if let tag = parseBareBracket(in: response) { return tag }
        // 3) No tag at all — the whole response is spoken text.
        return PointingTag(
            spokenText: response.trimmingCharacters(in: .whitespacesAndNewlines),
            centerInImagePixels: nil,
            boundingBoxInImagePixels: nil,
            label: nil,
            screenNumber: nil
        )
    }

    // MARK: - [POINT:...] form

    private static func parsePointTag(in response: String) -> PointingTag? {
        // Match ANY [POINT ...] tag and strip them all from the spoken text. We
        // accept two shapes the local vision models actually emit:
        //   • classic  "[POINT:1100,42:color inspector]"
        //   • attribute "[POINT x=\"736\" y=\"45\"]"  (what qwen2.5-vl emits — its
        //     pointing output is unreliable if we only accept the colon form).
        let pattern = #"\[POINT\b[^\]]*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let fullRange = NSRange(response.startIndex..., in: response)
        let matches = regex.matches(in: response, range: fullRange)
        guard let lastMatch = matches.last,
              let tagRange = Range(lastMatch.range, in: response) else {
            return nil
        }

        let spokenText = stripAllTagRanges(matches.map { $0.range }, from: response)

        // Inner payload: the tag with its brackets and the leading "POINT" /
        // optional ":" removed.
        var inner = String(response[tagRange])
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        if let keyword = inner.range(of: #"(?i)^\s*POINT\s*:?"#, options: .regularExpression) {
            inner.removeSubrange(keyword)
        }
        inner = inner.trimmingCharacters(in: .whitespaces)

        if inner.lowercased() == "none" || inner.isEmpty {
            return PointingTag(spokenText: spokenText, centerInImagePixels: nil,
                               boundingBoxInImagePixels: nil, label: "none", screenNumber: nil)
        }

        // Attribute form (x="..", y="..") first; fall back to the colon/comma form.
        let parsed = parseAttributeCoords(inner) ?? parseCoordinatePayload(inner)
        return PointingTag(
            spokenText: spokenText,
            centerInImagePixels: parsed.center,
            boundingBoxInImagePixels: parsed.box,
            label: parsed.label,
            screenNumber: parsed.screenNumber
        )
    }

    /// Parses an attribute-style payload like `x="736" y="45"` or
    /// `x1="10" y1="20" x2="30" y2="40" label="save"`. Returns nil if there's no
    /// `x`/`y` attribute (so the caller falls back to the colon/comma parser).
    private static func parseAttributeCoords(_ inner: String) -> ParsedPayload? {
        func number(_ key: String) -> Double? {
            let pattern = "(?i)\\b\(key)\\s*=\\s*\"?(-?\\d+(?:\\.\\d+)?)\"?"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(inner.startIndex..., in: inner)
            guard let match = regex.firstMatch(in: inner, range: range),
                  let group = Range(match.range(at: 1), in: inner) else { return nil }
            return Double(inner[group])
        }
        guard let x = number("x") ?? number("x1"), let y = number("y") ?? number("y1") else { return nil }
        var result = ParsedPayload()
        if let x2 = number("x2"), let y2 = number("y2") {
            result.box = CGRect(x: x, y: y, width: x2 - x, height: y2 - y)
            result.center = CGPoint(x: (x + x2) / 2, y: (y + y2) / 2)
        } else {
            result.center = CGPoint(x: x, y: y)
        }
        if let regex = try? NSRegularExpression(pattern: "(?i)\\blabel\\s*=\\s*\"([^\"]+)\""),
           let match = regex.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)),
           let group = Range(match.range(at: 1), in: inner) {
            result.label = String(inner[group])
        }
        return result
    }

    // MARK: - Bare "[x,y:label]" / "[x1,y1,x2,y2:label]" form

    private static func parseBareBracket(in response: String) -> PointingTag? {
        // Require at least a "number,number" pair and a non-empty label, so we
        // don't match arbitrary bracketed prose like "[1]" or "[note]".
        let pattern = #"\[\s*(\d{1,5}\s*,\s*\d{1,5}(?:\s*,\s*\d{1,5}\s*,\s*\d{1,5})?)\s*:\s*([^\]]+?)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let fullRange = NSRange(response.startIndex..., in: response)
        let matches = regex.matches(in: response, range: fullRange)
        guard let lastMatch = matches.last,
              let payloadRange = Range(lastMatch.range, in: response) else { return nil }

        let spokenText = stripAllTagRanges(matches.map { $0.range }, from: response)
        let inner = String(response[payloadRange].dropFirst().dropLast()) // strip [ ]
        let parsed = parseCoordinatePayload(inner)
        guard parsed.center != nil else { return nil }
        return PointingTag(
            spokenText: spokenText,
            centerInImagePixels: parsed.center,
            boundingBoxInImagePixels: parsed.box,
            label: parsed.label,
            screenNumber: parsed.screenNumber
        )
    }

    // MARK: - Shared payload parsing

    private struct ParsedPayload {
        var center: CGPoint?
        var box: CGRect?
        var label: String?
        var screenNumber: Int?
    }

    /// Parses a payload like "x,y:label", "x1,y1,x2,y2:label", or
    /// "x,y:label:screen2" into a center point (+ optional box, label, screen).
    private static func parseCoordinatePayload(_ payload: String) -> ParsedPayload {
        var result = ParsedPayload()

        // Pull out a trailing/anywhere "screenN" segment first.
        var working = payload
        if let screenRange = working.range(of: #"screen\s*\d+"#, options: [.regularExpression, .caseInsensitive]) {
            let screenToken = working[screenRange]
            if let digits = screenToken.range(of: #"\d+"#, options: .regularExpression) {
                result.screenNumber = Int(screenToken[digits])
            }
            working.removeSubrange(screenRange)
        }

        let segments = working.split(separator: ":", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }

        // The coordinate segment is the first one containing digits.
        let numberSegment = segments.first(where: { $0.range(of: #"\d"#, options: .regularExpression) != nil }) ?? ""
        let numbers = numberSegment
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        if numbers.count >= 4 {
            let box = CGRect(x: numbers[0], y: numbers[1],
                             width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
            result.box = box
            result.center = CGPoint(x: (numbers[0] + numbers[2]) / 2, y: (numbers[1] + numbers[3]) / 2)
        } else if numbers.count >= 2 {
            result.center = CGPoint(x: numbers[0], y: numbers[1])
        }

        // The label is the first non-numeric, non-screen segment.
        if let labelSegment = segments.first(where: { segment in
            !segment.isEmpty
                && segment.range(of: #"^[\d,\s]+$"#, options: .regularExpression) == nil
                && segment.lowercased().hasPrefix("screen") == false
        }) {
            result.label = labelSegment
        }

        return result
    }

    /// Removes every matched tag range from the response and tidies whitespace,
    /// leaving the clean text to be spoken aloud.
    private static func stripAllTagRanges(_ ranges: [NSRange], from response: String) -> String {
        var stripped = response
        // Remove from last to first so earlier ranges stay valid as we mutate.
        for nsRange in ranges.sorted(by: { $0.location > $1.location }) {
            if let swiftRange = Range(nsRange, in: stripped) {
                stripped.removeSubrange(swiftRange)
            }
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

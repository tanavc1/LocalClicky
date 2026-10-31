//
//  GestureSummary.swift
//  LocalBrainKit
//
//  Turns an InkAnalysis into one short plain-words sentence for the model's
//  prompt. No coordinates, only named regions of a 3x3 screen grid, because a
//  local vision model reads "the top right" far more reliably than numbers.
//
//  Example:
//    The user drew 2 marks in order while speaking: 1) circled an area in the
//    top right; 2) drew a line from the center toward the bottom; paused about
//    1.0 s in the center.
//
//  Deterministic, and capped near 300 characters by listing fewer marks
//  ("and N more") rather than cutting mid-phrase.
//

import CoreGraphics
import Foundation

public enum GestureSummary {
    public static let characterCap = 300
    private static let maxMarksListed = 5
    private static let maxDwellsListed = 2

    /// Nil when there is nothing to say (no marks and no dwells).
    public static func describe(_ analysis: InkAnalysis, screenSize: CGSize) -> String? {
        guard !analysis.isEmpty else { return nil }

        let markPhrases = analysis.marks.map { phrase(for: $0, screenSize: screenSize) }
        // Keep the longest pauses (in time order): at the 0.35 s reporting
        // threshold short hovers are common and would crowd out the real pause.
        let longest = Set(analysis.dwells.enumerated()
            .sorted { ($0.element.duration, $1.offset) > ($1.element.duration, $0.offset) }
            .prefix(maxDwellsListed).map(\.offset))
        let kept = analysis.dwells.enumerated().filter { longest.contains($0.offset) }.map(\.element)
        let dwellPhrases = kept.map { dwell -> String in
            return "paused about \(secondsText(dwell.duration)) s in the \(InkRegion.name(for: dwell.location, in: screenSize))"
        }

        var listed = min(markPhrases.count, maxMarksListed)
        while true {
            let text = assemble(markPhrases: markPhrases, listed: listed, dwellPhrases: Array(dwellPhrases))
            if text.count <= characterCap || listed <= 1 {
                return text.count <= characterCap ? text : hardTruncate(text)
            }
            listed -= 1
        }
    }

    // MARK: - Phrases

    /// One decimal, so a 0.4 s hover reads "0.4" and a long pause "2.4".
    static func secondsText(_ duration: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), duration)
    }

    private static func phrase(for mark: InkMark, screenSize: CGSize) -> String {
        switch mark.kind {
        case .circle:
            return "circled an area in the \(InkRegion.name(for: mark.center, in: screenSize))"
        case .line:
            let from = InkRegion.region(for: mark.start, in: screenSize)
            let to = InkRegion.region(for: mark.end, in: screenSize)
            if from == to { return "drew a short line in the \(from.name)" }
            return "drew a line from the \(from.name) toward the \(to.name)"
        case .scribble:
            return "scribbled over the \(InkRegion.name(for: mark.center, in: screenSize))"
        }
    }

    private static func assemble(markPhrases: [String], listed: Int, dwellPhrases: [String]) -> String {
        let total = markPhrases.count
        var parts: [String] = []
        switch total {
        case 0:
            // Only pauses: the first one carries the subject.
            parts.append("The user " + (dwellPhrases.first ?? "held the pointer still"))
            parts.append(contentsOf: dwellPhrases.dropFirst())
            return parts.joined(separator: "; ") + "."
        case 1:
            parts.append("The user drew 1 mark while speaking: \(markPhrases[0])")
        default:
            let numbered = markPhrases.prefix(listed).enumerated().map { "\($0.offset + 1)) \($0.element)" }
            var head = "The user drew \(total) marks in order while speaking: " + numbered.joined(separator: "; ")
            if listed < total { head += "; and \(total - listed) more" }
            parts.append(head)
        }
        parts.append(contentsOf: dwellPhrases)
        return parts.joined(separator: "; ") + "."
    }

    private static func hardTruncate(_ text: String) -> String {
        String(text.prefix(characterCap - 1)) + "."
    }
}

//
//  PointingLabel.swift
//  LocalBrainKit
//
//  The model's label for a [POINT:x,y:label] tag, cleaned up for the blue
//  speech bubble that appears when the cursor lands. A label that is missing,
//  a placeholder, or too long to read at a glance gives nil, and the overlay
//  keeps its random phrase instead.
//

import Foundation

public enum PointingLabel {
    public static let maxCharacters = 28
    public static let maxWords = 4

    /// Trimmed, whitespace-collapsed label, or nil when the bubble should keep
    /// its random phrase.
    public static func bubbleText(from label: String?) -> String? {
        guard let label else { return nil }
        let quotes = CharacterSet(charactersIn: "\"'`")
        let words = label
            .trimmingCharacters(in: .whitespacesAndNewlines.union(quotes))
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let cleaned = words.joined(separator: " ")
        guard !cleaned.isEmpty,
              words.count <= maxWords,
              cleaned.count <= maxCharacters else { return nil }
        let placeholders: Set<String> = ["none", "element", "null", "n/a"]
        guard !placeholders.contains(cleaned.lowercased()) else { return nil }
        return cleaned
    }
}

//
//  AccessibilitySummary.swift
//  LocalBrainKit
//
//  The pure half of the Accessibility harvest for the circled area. The app
//  walks the AX tree and hands over plain records; this turns them into a short
//  text block for the prompt. Secure fields never get through, not even as a
//  name: the user's password field has no business in a model prompt.
//

import CoreGraphics
import Foundation

public struct AccessibilityElementRecord: Equatable, Sendable {
    /// AX role, for example "AXButton".
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var description: String?
    public var url: String?
    /// For a link that has no address of its own and none on its nearest
    /// ancestors: a short phrase naming the nearest labelled ancestor it sits
    /// in, for example `group "Navigation"`. Nil otherwise.
    public var linkedFrom: String?
    public var isSecure: Bool
    /// Screen frame with a top-left origin (as AX reports it), so smaller y is higher.
    public var frame: CGRect

    public init(role: String? = nil, subrole: String? = nil, title: String? = nil,
                value: String? = nil, description: String? = nil, url: String? = nil,
                linkedFrom: String? = nil,
                isSecure: Bool = false, frame: CGRect = .zero) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.url = url
        self.linkedFrom = linkedFrom
        self.isSecure = isSecure
        self.frame = frame
    }
}

public enum AccessibilitySummary {
    public static let maxElements = 25
    public static let maxTextLength = 120
    /// Elements whose tops are within this many points share a reading row.
    static let rowTolerance: CGFloat = 8

    /// How many distinct, non-secure records carry any text. The harvester uses
    /// it to decide whether the point probes found enough to skip the tree walk.
    public static func usableCount(_ records: [AccessibilityElementRecord]) -> Int {
        deduplicated(records.filter { !isSecure($0) && hasContent($0) }).count
    }

    /// A short block for the prompt, or "" when no usable element remains.
    public static func summarize(_ records: [AccessibilityElementRecord],
                                 maxElements: Int = AccessibilitySummary.maxElements) -> String {
        let usable = deduplicated(records.filter { !isSecure($0) && hasContent($0) })
        let ordered = readingOrder(usable)
        guard !ordered.isEmpty else { return "" }

        let shown = ordered.prefix(maxElements)
        var lines = ["Elements inside the circled area, in reading order:"]
        lines.append(contentsOf: shown.map { "- " + line(for: $0) })
        if ordered.count > shown.count {
            lines.append("(\(ordered.count - shown.count) more not listed)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Filtering

    private static func isSecure(_ record: AccessibilityElementRecord) -> Bool {
        record.isSecure
            || record.role == "AXSecureTextField"
            || record.subrole == "AXSecureTextField"
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func hasContent(_ record: AccessibilityElementRecord) -> Bool {
        clean(record.title) != nil || clean(record.value) != nil
            || clean(record.description) != nil || clean(record.url) != nil
    }

    private static func deduplicated(_ records: [AccessibilityElementRecord]) -> [AccessibilityElementRecord] {
        var seen = Set<String>()
        var result: [AccessibilityElementRecord] = []
        for record in records {
            let key = [roleWords(record), clean(record.title), clean(record.value),
                       clean(record.description), clean(record.url), clean(record.linkedFrom)]
                .map { $0 ?? "" }.joined(separator: "\u{1F}")
            if seen.insert(key).inserted { result.append(record) }
        }
        return result
    }

    // MARK: - Order

    /// Top to bottom, then left to right, treating near-equal tops as one row.
    private static func readingOrder(_ records: [AccessibilityElementRecord]) -> [AccessibilityElementRecord] {
        let byTop = records.enumerated().sorted {
            ($0.element.frame.minY, $0.offset) < ($1.element.frame.minY, $1.offset)
        }.map(\.element)
        var rows: [[AccessibilityElementRecord]] = []
        var rowTop: CGFloat = 0
        for record in byTop {
            if let last = rows.indices.last, record.frame.minY - rowTop <= rowTolerance {
                rows[last].append(record)
            } else {
                rows.append([record])
                rowTop = record.frame.minY
            }
        }
        return rows.flatMap { row in
            row.enumerated().sorted {
                ($0.element.frame.minX, $0.offset) < ($1.element.frame.minX, $1.offset)
            }.map(\.element)
        }
    }

    // MARK: - Text

    private static func line(for record: AccessibilityElementRecord) -> String {
        let label = clean(record.title) ?? clean(record.description)
        var text = roleWords(record)
        if let label { text += " \"\(truncated(label))\"" }
        if let value = clean(record.value), value != label {
            text += ", value \"\(truncated(value))\""
        }
        if let url = clean(record.url) {
            text += ", link to \(truncated(url))"
        } else if let origin = clean(record.linkedFrom) {
            text += ", link with no address of its own, inside \(truncated(origin))"
        }
        return text
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maxTextLength else { return text }
        let cut = String(text.prefix(maxTextLength - 3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut + "..."
    }

    private static let subroleWords: [String: String] = [
        "AXSearchField": "search field",
        "AXTabButton": "tab",
        "AXCloseButton": "close button",
        "AXMinimizeButton": "minimize button",
        "AXFullScreenButton": "full-screen button",
        "AXToggle": "toggle",
        "AXSwitch": "switch",
        "AXSecureTextField": "secure text field",
    ]

    private static let roleWordsTable: [String: String] = [
        "AXButton": "button",
        "AXLink": "link",
        "AXTextField": "text field",
        "AXTextArea": "text area",
        "AXStaticText": "text",
        "AXImage": "image",
        "AXCheckBox": "checkbox",
        "AXRadioButton": "radio button",
        "AXPopUpButton": "pop-up menu",
        "AXMenuButton": "menu button",
        "AXMenuItem": "menu item",
        "AXComboBox": "combo box",
        "AXSlider": "slider",
        "AXHeading": "heading",
        "AXTabGroup": "tab group",
        "AXList": "list",
        "AXTable": "table",
        "AXRow": "row",
        "AXCell": "cell",
        "AXOutline": "outline",
        "AXToolbar": "toolbar",
        "AXGroup": "group",
        "AXWebArea": "web page",
        "AXDisclosureTriangle": "disclosure triangle",
        "AXProgressIndicator": "progress indicator",
    ]

    /// Plain words for the element kind. A known subrole wins over the role;
    /// an unknown role falls back to its AX name split into lowercase words.
    public static func roleWords(_ record: AccessibilityElementRecord) -> String {
        if let subrole = record.subrole, let words = subroleWords[subrole] { return words }
        guard let role = record.role, !role.isEmpty else { return "element" }
        if let words = roleWordsTable[role] { return words }
        let name = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        var words = ""
        for character in name {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(Character(character.lowercased()))
        }
        return words.isEmpty ? "element" : words
    }
}

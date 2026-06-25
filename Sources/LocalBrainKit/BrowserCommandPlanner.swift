//
//  BrowserCommandPlanner.swift
//  LocalBrainKit
//
//  Turns a spoken command ("open a new tab, go to my gmail, and open up a draft")
//  into a small list of concrete URLs to open. This is deliberately deterministic
//  — a known-site map plus a few patterns — rather than asking a 3B model to emit
//  JSON, because for browser navigation correctness and safety matter more than
//  flexibility:
//
//   * Accurate: "open a draft" always resolves to Gmail's real compose URL, never
//     a guessed click on a 3B model's idea of where the button is.
//   * Safe: every action is an ordinary URL open (reversible, no form submit, no
//     page scripting, nothing destructive), so it's always in the "auto-run safe"
//     category. The executor is structurally incapable of sending or deleting.
//
//  Pure and side-effect-free so it can be unit-tested from the harness.
//

import Foundation

/// One concrete thing to open in the browser.
public struct BrowserAction: Equatable, Sendable {
    public let url: String
    public let label: String
    public init(url: String, label: String) {
        self.url = url
        self.label = label
    }
}

/// The result of planning a spoken browser command.
public struct BrowserPlan: Equatable, Sendable {
    public let actions: [BrowserAction]
    /// What the companion should say while doing it (or to explain it can't).
    public let spokenSummary: String
    /// True when we understood the command well enough to act.
    public var isUnderstood: Bool { !actions.isEmpty }

    public init(actions: [BrowserAction], spokenSummary: String) {
        self.actions = actions
        self.spokenSummary = spokenSummary
    }
}

public enum BrowserCommandPlanner {

    /// Gmail's compose URL — opens a fresh draft window directly, no clicking.
    static let gmailComposeURL = "https://mail.google.com/mail/?view=cm&fs=1&tf=1"

    /// Site keyword → URL, ordered most-specific-first so "google maps" wins over
    /// "maps"/"google" and is consumed before the generic terms are checked.
    static let siteMap: [(keyword: String, url: String, label: String)] = [
        ("google calendar", "https://calendar.google.com/", "google calendar"),
        ("google drive", "https://drive.google.com/", "google drive"),
        ("google docs", "https://docs.google.com/document/u/0/", "google docs"),
        ("google sheets", "https://docs.google.com/spreadsheets/u/0/", "google sheets"),
        ("google slides", "https://docs.google.com/presentation/u/0/", "google slides"),
        ("google maps", "https://maps.google.com/", "google maps"),
        ("stack overflow", "https://stackoverflow.com/", "stack overflow"),
        ("gmail", "https://mail.google.com/mail/u/0/", "gmail"),
        ("calendar", "https://calendar.google.com/", "calendar"),
        ("drive", "https://drive.google.com/", "drive"),
        ("docs", "https://docs.google.com/document/u/0/", "docs"),
        ("sheets", "https://docs.google.com/spreadsheets/u/0/", "sheets"),
        ("slides", "https://docs.google.com/presentation/u/0/", "slides"),
        ("maps", "https://maps.google.com/", "maps"),
        ("youtube", "https://www.youtube.com/", "youtube"),
        ("github", "https://github.com/", "github"),
        ("twitter", "https://twitter.com/", "twitter"),
        ("reddit", "https://www.reddit.com/", "reddit"),
        ("amazon", "https://www.amazon.com/", "amazon"),
        ("wikipedia", "https://www.wikipedia.org/", "wikipedia"),
        ("linkedin", "https://www.linkedin.com/", "linkedin"),
        ("notion", "https://www.notion.so/", "notion"),
        ("spotify", "https://open.spotify.com/", "spotify"),
        ("netflix", "https://www.netflix.com/", "netflix"),
        ("outlook", "https://outlook.live.com/", "outlook"),
        ("google", "https://www.google.com/", "google"),
    ]

    public static func plan(for transcript: String) -> BrowserPlan {
        let text = transcript.lowercased()

        // 1) Compose / draft an email → Gmail compose (a fresh draft, ready to type).
        if wantsEmailDraft(text) {
            return BrowserPlan(
                actions: [BrowserAction(url: gmailComposeURL, label: "gmail draft")],
                spokenSummary: "sure, opening gmail and starting a new draft for you.")
        }

        var actions: [BrowserAction] = []
        var labels: [String] = []

        // 2) An explicit web search.
        if let query = searchQuery(in: text) {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            actions.append(BrowserAction(url: "https://www.google.com/search?q=\(encoded)",
                                         label: "search for \(query)"))
            labels.append("searching for \(query)")
        }

        // 3) An explicit URL/domain in the command.
        if let url = explicitURL(in: text) {
            actions.append(BrowserAction(url: url, label: url))
            labels.append("opening \(url)")
        }

        // 4) Known sites (consume each match so generic terms don't double-fire).
        if actions.isEmpty {
            var working = " \(text) "
            for site in siteMap where working.contains(site.keyword) {
                actions.append(BrowserAction(url: site.url, label: site.label))
                labels.append("opening \(site.label)")
                working = working.replacingOccurrences(of: site.keyword, with: " ")
            }
        }

        // 5) Bare "new tab" with no destination → a fresh tab on Google.
        if actions.isEmpty && (text.contains("new tab") || text.contains("open a tab")) {
            actions.append(BrowserAction(url: "https://www.google.com/", label: "a new tab"))
            labels.append("opening a new tab")
        }

        guard !actions.isEmpty else {
            return BrowserPlan(actions: [],
                spokenSummary: "i can open sites or search the web for you — for example, say open gmail, or search for something.")
        }
        return BrowserPlan(actions: actions, spokenSummary: phrase(from: labels))
    }

    // MARK: - Patterns

    static func wantsEmailDraft(_ text: String) -> Bool {
        if text.contains("draft") { return true }
        if text.contains("compose") { return true }
        let emaily = text.contains("email") || text.contains("e-mail")
        let creates = text.contains("write") || text.contains("start") || text.contains("new") || text.contains("open")
        return emaily && creates
    }

    static func searchQuery(in text: String) -> String? {
        let triggers = ["search the web for ", "search google for ", "search for ", "google search for ",
                        "look up ", "search "]
        for trigger in triggers where text.contains(trigger) {
            guard let range = text.range(of: trigger) else { continue }
            var query = String(text[range.upperBound...])
            for suffix in [" online", " on the web", " on google"] {
                if query.hasSuffix(suffix) { query = String(query.dropLast(suffix.count)) }
            }
            query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty { return query }
        }
        // "google <something>" as a verb (but not "google maps/docs/...").
        if text.hasPrefix("google ") {
            let rest = String(text.dropFirst("google ".count)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty && !siteMap.contains(where: { $0.keyword == "google \(rest)" }) {
                return rest
            }
        }
        return nil
    }

    static func explicitURL(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "," }) {
            let word = String(token)
            if word.hasPrefix("http://") || word.hasPrefix("https://") { return word }
            // A bare domain like "example.com" or "docs.rs".
            let tlds = [".com", ".org", ".net", ".io", ".dev", ".gov", ".edu", ".co"]
            if tlds.contains(where: { word.hasSuffix($0) || word.contains("\($0)/") }),
               !word.contains(" ") {
                return "https://\(word)"
            }
        }
        return nil
    }

    static func phrase(from labels: [String]) -> String {
        guard !labels.isEmpty else { return "" }
        if labels.count == 1 { return "sure, \(labels[0])." }
        let head = labels.dropLast().joined(separator: ", ")
        return "sure, \(head) and \(labels.last!)."
    }
}

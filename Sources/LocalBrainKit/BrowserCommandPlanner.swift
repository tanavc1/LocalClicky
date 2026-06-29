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

        if let sitePlan = siteSpecificPlan(for: text) {
            return sitePlan
        }

        // Explicit "search X on my computer / in google / google X" → a Google
        // results page (opened in Chrome if present by the executor). Handled
        // here so the "on my computer / in google" phrasing is cleaned correctly.
        if let computerQuery = ComputerActionPlanner.computerSearchQuery(from: text) {
            let encoded = computerQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? computerQuery
            return BrowserPlan(
                actions: [BrowserAction(url: "https://www.google.com/search?q=\(encoded)",
                                        label: "search for \(computerQuery)")],
                spokenSummary: "searching google for \(computerQuery).")
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

    static func siteSpecificPlan(for text: String) -> BrowserPlan? {
        if let query = youtubeChannelQuery(in: text) {
            return BrowserPlan(
                actions: [BrowserAction(
                    url: youtubeSearchURL(query: "\(query) channel"),
                    label: "youtube channel search for \(query)"
                )],
                spokenSummary: "sure, opening youtube results for \(query)'s channel.")
        }

        if let query = siteSearchQuery(in: text, siteNames: ["youtube"]) {
            return BrowserPlan(
                actions: [BrowserAction(url: youtubeSearchURL(query: query), label: "youtube search for \(query)")],
                spokenSummary: "sure, searching youtube for \(query).")
        }

        if let query = siteSearchQuery(in: text, siteNames: ["google maps", "maps"]) {
            return BrowserPlan(
                actions: [BrowserAction(url: googleMapsSearchURL(query: query), label: "maps search for \(query)")],
                spokenSummary: "sure, opening maps for \(query).")
        }

        if let query = siteSearchQuery(in: text, siteNames: ["github"]) {
            return BrowserPlan(
                actions: [BrowserAction(url: githubSearchURL(query: query), label: "github search for \(query)")],
                spokenSummary: "sure, searching github for \(query).")
        }

        if let query = siteSearchQuery(in: text, siteNames: ["reddit"]) {
            return BrowserPlan(
                actions: [BrowserAction(url: redditSearchURL(query: query), label: "reddit search for \(query)")],
                spokenSummary: "sure, searching reddit for \(query).")
        }

        if let query = siteSearchQuery(in: text, siteNames: ["amazon"]) {
            return BrowserPlan(
                actions: [BrowserAction(url: amazonSearchURL(query: query), label: "amazon search for \(query)")],
                spokenSummary: "sure, searching amazon for \(query).")
        }

        if let query = siteSearchQuery(in: text, siteNames: ["wikipedia"]) {
            return BrowserPlan(
                actions: [BrowserAction(url: wikipediaSearchURL(query: query), label: "wikipedia search for \(query)")],
                spokenSummary: "sure, searching wikipedia for \(query).")
        }

        if let query = siteSearchQuery(in: text, siteNames: ["gmail", "mail"]) {
            return BrowserPlan(
                actions: [BrowserAction(url: gmailSearchURL(query: query), label: "gmail search for \(query)")],
                spokenSummary: "sure, searching gmail for \(query).")
        }

        return nil
    }

    static func youtubeChannelQuery(in text: String) -> String? {
        guard text.contains("youtube"), text.contains("channel") else { return nil }
        return siteSearchQuery(in: text, siteNames: ["youtube"], trailingWordsToDrop: ["channel"])
    }

    static func siteSearchQuery(
        in text: String,
        siteNames: [String],
        trailingWordsToDrop: [String] = []
    ) -> String? {
        guard let siteRange = siteNames.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return nil
        }

        let afterSite = String(text[siteRange.upperBound...])
        let beforeSite = String(text[..<siteRange.lowerBound])
        let candidates = [
            queryAfterSiteConnector(afterSite, trailingWordsToDrop: trailingWordsToDrop),
            queryBeforeSiteConnector(beforeSite, trailingWordsToDrop: trailingWordsToDrop),
        ]
        return candidates.compactMap { $0 }.first
    }

    static func queryAfterSiteConnector(_ text: String, trailingWordsToDrop: [String]) -> String? {
        let connectors = [
            " and go to ", " and open ", " and search for ", " and search ",
            " then go to ", " then open ", " then search for ", " then search ",
            " go to ", " open ", " search for ", " search ", " find ",
            " look up ", " pull up ", " take me to "
        ]
        for connector in connectors where text.contains(connector) {
            guard let range = text.range(of: connector) else { continue }
            let raw = String(text[range.upperBound...])
            if let query = cleanedSiteQuery(raw, trailingWordsToDrop: trailingWordsToDrop) {
                return query
            }
        }
        return nil
    }

    static func queryBeforeSiteConnector(_ text: String, trailingWordsToDrop: [String]) -> String? {
        let connectors = ["search for ", "search ", "find ", "look up ", "open ", "go to ",
                          " search for ", " search ", " find ", " look up ", " open ", " go to "]
        for connector in connectors where text.contains(connector) {
            guard let range = text.range(of: connector) else { continue }
            var raw = String(text[range.upperBound...])
            if raw.contains(" and ") { continue }
            for suffix in [" on ", " in ", " at "] {
                if let suffixRange = raw.range(of: suffix, options: .backwards) {
                    raw = String(raw[..<suffixRange.lowerBound])
                    break
                }
            }
            if let query = cleanedSiteQuery(raw, trailingWordsToDrop: trailingWordsToDrop) {
                return query
            }
        }
        return nil
    }

    static func cleanedSiteQuery(_ raw: String, trailingWordsToDrop: [String]) -> String? {
        var query = raw
        for stopPhrase in [" and then ", " then ", " after that "] {
            if let range = query.range(of: stopPhrase) {
                query = String(query[..<range.lowerBound])
            }
        }
        query = query.replacingOccurrences(of: " my ", with: " ")
            .replacingOccurrences(of: " the ", with: " ")
            .replacingOccurrences(of: " a ", with: " ")
            .replacingOccurrences(of: " an ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for word in trailingWordsToDrop {
            if query == word { return nil }
            if query.hasSuffix(" \(word)") {
                query = String(query.dropLast(word.count + 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return query.isEmpty ? nil : query
    }

    static func encodedQuery(_ query: String) -> String {
        query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    }

    static func youtubeSearchURL(query: String) -> String {
        "https://www.youtube.com/results?search_query=\(encodedQuery(query))"
    }

    static func googleMapsSearchURL(query: String) -> String {
        "https://www.google.com/maps/search/?api=1&query=\(encodedQuery(query))"
    }

    static func githubSearchURL(query: String) -> String {
        "https://github.com/search?q=\(encodedQuery(query))"
    }

    static func redditSearchURL(query: String) -> String {
        "https://www.reddit.com/search/?q=\(encodedQuery(query))"
    }

    static func amazonSearchURL(query: String) -> String {
        "https://www.amazon.com/s?k=\(encodedQuery(query))"
    }

    static func wikipediaSearchURL(query: String) -> String {
        "https://en.wikipedia.org/w/index.php?search=\(encodedQuery(query))"
    }

    static func gmailSearchURL(query: String) -> String {
        "https://mail.google.com/mail/u/0/#search/\(encodedQuery(query))"
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

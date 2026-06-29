//
//  ComputerActionPlanner.swift
//  LocalBrainKit
//
//  Pure, deterministic detection + parsing for LocalClicky's "computer use"
//  actions: setting a timer, controlling Spotify, and the explicit "search this
//  on my computer" browser search. Kept pure (no AppKit, no side effects) so it
//  can be unit-tested from the harness with no GUI — the actual side effects
//  (scheduling the timer, scripting Spotify, opening the browser) live in the app
//  target. Each detector is deliberately tight so it never fires on a normal
//  question.
//

import Foundation

public enum ComputerActionPlanner {

    // MARK: - Timer

    public struct TimerRequest: Equatable, Sendable {
        /// Total duration in seconds.
        public let seconds: Int
        /// A natural spoken form of the duration, e.g. "4 minutes", "90 seconds".
        public let spokenDuration: String
        public init(seconds: Int, spokenDuration: String) {
            self.seconds = seconds
            self.spokenDuration = spokenDuration
        }
    }

    /// Detects "set a timer for 4 minutes", "timer for 30 seconds", "set a 5
    /// minute timer", "give me a two minute timer". Requires the word "timer" and
    /// a parseable duration, so it never fires on a normal sentence.
    public static func timerRequest(from transcript: String) -> TimerRequest? {
        let text = normalize(transcript)
        guard text.contains("timer") || text.contains("countdown") else { return nil }
        guard let total = parseDurationSeconds(in: text), total > 0, total <= 24 * 3600 else { return nil }
        return TimerRequest(seconds: total, spokenDuration: spokenDuration(forSeconds: total))
    }

    // MARK: - Spotify

    public enum SpotifyAction: Equatable, Sendable {
        case play          // resume / start playback
        case pause
        case next
        case previous
        case playQuery(String)   // "play <song/artist> on spotify"
    }

    /// Detects Spotify control. Requires the word "spotify" so it never hijacks a
    /// generic "play"/"pause". Returns the most specific action.
    public static func spotifyAction(from transcript: String) -> SpotifyAction? {
        let text = normalize(transcript)
        guard text.contains("spotify") else { return nil }

        if text.contains("pause") || text.contains("stop the music") || text.contains("stop the song")
            || text.contains("stop playing") {
            return .pause
        }
        if text.contains("next") || text.contains("skip") {
            return .next
        }
        if text.contains("previous") || text.contains("go back") || text.contains("last song")
            || text.contains("last track") {
            return .previous
        }

        // "play <something> on spotify" → search-and-show that something.
        if let query = spotifyPlayQuery(in: text) {
            return .playQuery(query)
        }

        // Bare "play / resume / start ... spotify".
        if text.contains("play") || text.contains("resume") || text.contains("start the music")
            || text.contains("unpause") {
            return .play
        }
        return nil
    }

    /// Pulls the song/artist out of "play <query> on spotify" (or "on spotify play
    /// <query>"). Returns nil for a bare "play on spotify" (handled as `.play`).
    static func spotifyPlayQuery(in normalizedText: String) -> String? {
        guard normalizedText.contains("play") else { return nil }
        var text = normalizedText

        // Drop a leading "play" / "can you play" / "could you play".
        for opener in ["can you play ", "could you play ", "please play ", "go ahead and play ",
                       "play me ", "play the song ", "play the track ", "play song ", "play "] {
            if let range = text.range(of: opener) {
                text = String(text[range.upperBound...])
                break
            }
        }
        // Remove the spotify mention and common connectors around it.
        for marker in [" on spotify", " in spotify", " spotify", " on my spotify", " using spotify"] {
            text = text.replacingOccurrences(of: marker, with: " ")
        }
        if text.hasPrefix("spotify ") { text = String(text.dropFirst("spotify ".count)) }
        let query = text
            .replacingOccurrences(of: " for me", with: " ")
            .replacingOccurrences(of: "spotify", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare "play (on) spotify" leaves nothing meaningful → not a song query
        // (handled as `.play` instead).
        let bareWords: Set<String> = ["music", "something", "a song", "the music", "some music", "song"]
        guard !query.isEmpty, !bareWords.contains(query) else { return nil }
        return query
    }

    // MARK: - "Search this on my computer" (browser search)

    /// Detects an explicit request to search the web *in the user's browser on
    /// their computer* — "search X on my computer", "search X in google", "google
    /// X". Returns the cleaned query. Deliberately tight: only fires on an
    /// explicit computer/google search phrasing, so it doesn't compete with the
    /// spoken web-answer route.
    public static func computerSearchQuery(from transcript: String) -> String? {
        let text = normalize(transcript)

        // Must be an explicit "do this in my browser/google" request.
        let computerMarkers = ["on my computer", "on my mac", "in my browser", "in the browser",
                               "in google", "on google", "in chrome", "in my chrome",
                               "in a browser", "pull up google", "open google and search"]
        let hasComputerMarker = computerMarkers.contains(where: text.contains)

        // Extract the query after a search verb.
        let triggers = ["search for ", "search up ", "look up ", "google ", "search "]
        for trigger in triggers {
            guard let range = text.range(of: trigger) else { continue }
            // "google maps/docs/..." is a site, not a search verb.
            if trigger == "google " {
                let rest = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("maps") || rest.hasPrefix("docs") || rest.hasPrefix("drive")
                    || rest.hasPrefix("sheets") || rest.hasPrefix("calendar") { return nil }
            }
            var query = String(text[range.upperBound...])
            query = stripSearchSuffixes(query)
            query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { continue }
            // "search X" alone (no computer marker, no google) is ambiguous — only
            // treat it as a browser search when it's explicitly a computer/google
            // search, OR the verb itself is "google ".
            if trigger == "google " || hasComputerMarker {
                return query
            }
        }
        return nil
    }

    static func stripSearchSuffixes(_ query: String) -> String {
        var result = query
        let suffixes = [" on my computer", " on my mac", " in my browser", " in the browser",
                        " in google", " on google", " in chrome", " in my chrome", " in a browser",
                        " on the internet", " online", " for me", " please", " on the web", " on safari"]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
                changed = true
            }
        }
        return result
    }

    // MARK: - Duration parsing

    /// Parses a spoken duration into total seconds: "4 minutes", "1 hour 30
    /// minutes", "ninety seconds", "an hour and a half". Returns nil if none.
    static func parseDurationSeconds(in text: String) -> Int? {
        var total = 0
        var found = false

        // unit → seconds-per-unit, longest spellings first.
        let units: [(names: [String], multiplier: Int)] = [
            (["hours", "hour", "hr", "hrs"], 3600),
            (["minutes", "minute", "min", "mins"], 60),
            (["seconds", "second", "sec", "secs"], 1),
        ]

        let words = text.split(whereSeparator: { $0 == " " }).map(String.init)
        for (index, word) in words.enumerated() {
            for unit in units where unit.names.contains(word) {
                // The amount is the token immediately before the unit word.
                let amount: Int?
                if index > 0 {
                    amount = numberValue(words[index - 1])
                } else {
                    amount = nil
                }
                // "an hour", "a minute" → 1.
                if let amount {
                    total += amount * unit.multiplier
                    found = true
                } else if index > 0 && (words[index - 1] == "a" || words[index - 1] == "an") {
                    total += unit.multiplier
                    found = true
                }
            }
        }

        // "half" → +30 minutes / +30 seconds when it follows "and a half" of a unit.
        if text.contains("and a half") {
            if text.contains("hour") { total += 1800; found = true }
            else if text.contains("minute") { total += 30; found = true }
        }

        return found ? total : nil
    }

    /// A spoken digit ("4") or number word ("four", "ninety", "twenty five").
    static func numberValue(_ token: String) -> Int? {
        if let value = Int(token) { return value }
        return Self.numberWords[token]
    }

    static let numberWords: [String: Int] = {
        var map: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
            "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
            "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
            "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90,
        ]
        return map
    }()

    static func spokenDuration(forSeconds seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if secs > 0 { parts.append("\(secs) second\(secs == 1 ? "" : "s")") }
        if parts.isEmpty { return "0 seconds" }
        if parts.count == 1 { return parts[0] }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    static func normalize(_ transcript: String) -> String {
        transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

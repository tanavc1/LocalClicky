//
//  AppCommandPlanner.swift
//  LocalBrainKit
//
//  Turns a spoken command ("launch spotify", "open the notes app") into the
//  *name* of a macOS application to open. Like BrowserCommandPlanner this is
//  deliberately deterministic and pure — no model in the loop — because the only
//  safe, reliable agentic action here is "open an app the user already has
//  installed." The app layer (LocalAppLauncher) resolves the name to an actual
//  installed .app and launches it via NSWorkspace; if there's no match it can
//  fall back to a web search or tell the user plainly. Nothing this produces can
//  do anything but launch an app, so it stays in the "auto-run safe" category.
//
//  Pure and side-effect-free so it can be unit-tested from the harness.
//

import Foundation

public enum AppCommandPlanner {

    /// Verbs that, in this companion's context, mean "open an application."
    /// Kept distinct from BrowserCommandPlanner's navigation verbs; "pull up" /
    /// "go to" / "visit" stay browser-only on purpose.
    static let launchVerbs = ["launch ", "open up ", "open ", "start up ", "fire up ", "boot up ", "run "]

    /// Common apps that DON'T collide with the browser site map, so a bare
    /// "open <name>" should open the app rather than a website. Names that are
    /// also web brands — calendar, maps, notion, spotify, netflix, youtube… — are
    /// intentionally left out: those stay with the browser planner unless the
    /// user explicitly says "launch X" or "the X app", which removes the
    /// ambiguity. Browsers (chrome/safari/…) and dev/chat apps are safe because
    /// they have no entry in the browser site map.
    static let knownAppNames: Set<String> = [
        "finder", "terminal", "notes", "calculator", "reminders", "messages",
        "imessage", "mail", "facetime", "contacts", "photos", "music",
        "podcasts", "preview", "textedit", "text edit", "system settings",
        "system preferences", "settings", "activity monitor", "app store",
        "disk utility", "quicktime", "quicktime player", "stickies", "weather",
        "clock", "stocks", "voice memos", "freeform", "books", "find my",
        "shortcuts", "automator", "console", "home", "passwords",
        "xcode", "slack", "discord", "zoom", "telegram", "whatsapp", "obsidian",
        "visual studio code", "vs code", "vscode", "chrome", "google chrome",
        "safari", "firefox", "arc",
        // Spotify has a real desktop app users expect "open spotify" to launch
        // (not the web player). If it isn't installed, the open-app handler falls
        // back to the web automatically.
        "spotify",
    ]

    /// The name of an application to launch, extracted from a spoken command, or
    /// nil if this isn't an app-launch request. Cleaned of filler ("the", "my",
    /// "please", "for me") and truncated at a conjunction so "open notes and
    /// write a list" yields just "notes".
    public static func appLaunchName(from transcript: String) -> String? {
        let text = " " + transcript.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines) + " "

        // 1) An explicit "... <name> app" / "... <name> application" phrasing is
        //    unambiguous: the user is naming an application.
        if let viaAppKeyword = nameBeforeAppKeyword(in: text) {
            return viaAppKeyword
        }

        // 2) "launch <name>" — "launch" only ever means open an application.
        if let range = text.range(of: " launch ") {
            if let name = cleanedAppName(String(text[range.upperBound...])) {
                return name
            }
        }

        // 3) A launch verb immediately followed by a known app name.
        for verb in launchVerbs {
            guard let range = text.range(of: " " + verb) else { continue }
            let rest = String(text[range.upperBound...])
            guard let candidate = cleanedAppName(rest) else { continue }
            if knownAppNames.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// True when the transcript is an app-launch request.
    public static func isAppLaunch(_ transcript: String) -> Bool {
        appLaunchName(from: transcript) != nil
    }

    /// Common spoken shorthands → the canonical app name (lowercased) as it tends
    /// to appear on disk. Lets "settings", "vs code", "imessage" resolve.
    public static let appNameAliases: [String: String] = [
        "settings": "system settings",
        "system preferences": "system settings",
        "preferences": "system settings",
        "vs code": "visual studio code",
        "vscode": "visual studio code",
        "code": "visual studio code",
        "imessage": "messages",
        "text edit": "textedit",
        "quicktime": "quicktime player",
        "quick time": "quicktime player",
        "chrome": "google chrome",
    ]

    /// Resolves a spoken app name to the best matching name from a list of
    /// installed app display names (all lowercased). Deterministic: exact match,
    /// then space/punctuation-insensitive match, then the shortest prefix/word
    /// match (so "chrome" → "google chrome" but never a longer unrelated title).
    /// Pure so the matching can be unit-tested without touching the filesystem.
    public static func resolveAppName(_ spokenName: String, installedNames: [String]) -> String? {
        let query = spokenName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let effective = appNameAliases[query] ?? query

        // 1) Exact match.
        if installedNames.contains(effective) { return effective }

        // 2) Ignore spaces ("vs code" vs "vscode", "find my" vs "findmy").
        let collapsed = effective.replacingOccurrences(of: " ", with: "")
        if let match = installedNames.first(where: {
            $0.replacingOccurrences(of: " ", with: "") == collapsed
        }) {
            return match
        }

        // 3) Conservative partial match — shortest candidate wins:
        //    - the app name starts with what was said ("calc" → "calculator"),
        //    - the spoken phrase is a whole word in the name ("monitor" →
        //      "activity monitor"),
        //    - or (for queries of 4+ chars) the name contains it ("term" →
        //      "terminal").
        //    We deliberately do NOT match when the *spoken* word merely starts
        //    with the app name, which would turn "photoshop" into "photos".
        let candidates = installedNames.filter { name in
            if name.hasPrefix(effective) { return true }
            if name.split(separator: " ").contains(Substring(effective)) { return true }
            if effective.count >= 4 && name.contains(effective) { return true }
            return false
        }
        return candidates.min(by: { $0.count < $1.count })
    }

    // MARK: - Helpers

    /// Captures the name in "<verb> [the/my] <NAME> app[lication]".
    private static func nameBeforeAppKeyword(in text: String) -> String? {
        let pattern = #"(?:launch|open up|open|start up|start|fire up|boot up|run)\s+(?:the\s+|my\s+|a\s+)?(.+?)\s+app(?:lication)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let nameRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return cleanedAppName(String(text[nameRange]) + " ")
    }

    /// Trims filler words and stops at the first conjunction so we keep only the
    /// application's name.
    private static func cleanedAppName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop a leading article/possessive.
        for prefix in ["the ", "my ", "a ", "an "] {
            if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        }

        // Stop at a conjunction / follow-on clause.
        for stop in [" and ", " then ", " after that ", ", ", " for me", " please", " app", " application"] {
            if let range = name.range(of: stop) {
                name = String(name[..<range.lowerBound])
            }
        }

        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        // Reject empties and runaway phrases — a real app name is short.
        guard !name.isEmpty, name.split(separator: " ").count <= 4 else { return nil }
        return name
    }
}

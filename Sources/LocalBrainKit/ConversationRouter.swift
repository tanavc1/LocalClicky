//
//  ConversationRouter.swift
//  LocalBrainKit
//
//  Decides, per spoken turn, which pipeline should handle it:
//
//    .screen          — capture a screenshot and use the vision model (the user
//                       is asking about something visible / wants the cursor to
//                       point at something)
//    .text            — use the fast text model with conversation history (a
//                       self-contained question or a follow-up to a previous
//                       answer, like "add two to that")
//    .browserCommand  — the user is telling LocalClicky to *do* something in the
//                       browser ("open a new tab and go to gmail")
//
//  This exists because the app used to screenshot on *every* turn in vision mode,
//  so the screen-grounded prompt hijacked plain follow-ups ("what's 3 times 5" →
//  "15", then "add 2 to that" → it starts describing the screen). Routing is a
//  pure function so it can be unit-tested from the harness with no Ollama, no
//  screen, and no GUI. It is deliberately conservative: in vision mode it only
//  pulls *away* from the screen when there's a positive signal the turn is
//  self-contained, so existing screen behavior is preserved.
//

import Foundation

public enum ConversationRoute: Equatable, Sendable {
    case screen
    case text
    case browserCommand
}

public enum ConversationRouter {

    /// Everything the router needs that isn't in the transcript itself.
    public struct Context: Sendable {
        /// The user's manual mode toggle is on "vision" (can use the screen).
        public let visionModeSelected: Bool
        /// Screen-content permission is granted (we can actually capture).
        public let screenAvailable: Bool
        /// The immediately-preceding answered turn used the screen. Lets us read
        /// pronouns correctly: "add 2 to that" after a *text* turn refers to the
        /// last answer, not to anything on screen.
        public let previousTurnUsedScreen: Bool
        /// There's at least one prior exchange this session.
        public let hasConversationHistory: Bool

        public init(visionModeSelected: Bool,
                    screenAvailable: Bool,
                    previousTurnUsedScreen: Bool,
                    hasConversationHistory: Bool) {
            self.visionModeSelected = visionModeSelected
            self.screenAvailable = screenAvailable
            self.previousTurnUsedScreen = previousTurnUsedScreen
            self.hasConversationHistory = hasConversationHistory
        }
    }

    public static func route(transcript: String, context: Context) -> ConversationRoute {
        let text = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Explicit "do something in the browser" wins over everything — it's
        //    an action request, not a question.
        if isBrowserCommand(text) { return .browserCommand }

        // 2) No screen this turn (text-only mode, or no permission) → text path.
        guard context.visionModeSelected, context.screenAvailable else { return .text }

        // 3) Vision mode with the screen available is the default. Only divert to
        //    the text model when the turn is clearly self-contained.
        if isClearlyTextOnly(text, context: context) { return .text }
        return .screen
    }

    // MARK: - Browser commands

    /// Imperative verb aimed at the web/browser. Tightly gated so on-screen
    /// requests like "open the file menu" or "click the settings button" do NOT
    /// get mistaken for browser navigation.
    static func isBrowserCommand(_ text: String) -> Bool {
        // A new browser tab is unambiguous.
        if text.contains("new tab") || text.contains("open a tab") || text.contains("open another tab") {
            return true
        }
        // Web searches.
        if text.contains("search the web") || text.contains("search google")
            || text.contains("google search") || text.contains("search for ")
            || text.contains("look up ") && (text.contains(" online") || text.contains(" on the web"))
            || text.hasPrefix("google ") {
            return true
        }
        // Compose / draft an email is a browser action (Gmail compose).
        let composeVerb = ["compose", "draft", "write", "start", "open", "new"].contains { text.contains($0) }
        if composeVerb && (text.contains("email") || text.contains("e-mail") || text.contains("draft")) {
            // "open up a draft", "compose an email", "write an email", "new email"
            return true
        }

        // Navigation verb + a web target (site name, url, "tab", "website"...).
        let navVerbs = ["open ", "go to ", "goto ", "navigate to ", "navigate ", "pull up ",
                        "bring up ", "take me to ", "visit ", "head to ", "jump to "]
        let hasNavVerb = navVerbs.contains { text.contains($0) }
        guard hasNavVerb else { return false }

        if hasWebTarget(text) { return true }
        return false
    }

    /// True if the text names something clearly on the web: a known site, a URL,
    /// or a generic web noun.
    static func hasWebTarget(_ text: String) -> Bool {
        if text.contains("http://") || text.contains("https://") || text.contains("www.")
            || text.contains(".com") || text.contains(".org") || text.contains(".net")
            || text.contains(".io") || text.contains(".dev") || text.contains(".gov") {
            return true
        }
        let webNouns = ["website", "web site", "web page", "webpage", "browser", " tab",
                        "my email", "my inbox", "my mail", "the internet"]
        if webNouns.contains(where: text.contains) { return true }
        return knownSites.contains { text.contains($0) }
    }

    /// Site keywords the planner also knows how to turn into URLs. Kept in sync
    /// (loosely) with BrowserCommandPlanner's site map.
    static let knownSites: [String] = [
        "gmail", "google", "youtube", "calendar", "google maps", "maps",
        "google drive", "drive", "google docs", "docs", "sheets", "slides",
        "github", "twitter", "reddit", "amazon", "wikipedia",
        "stack overflow", "stackoverflow", "linkedin", "notion", "spotify",
        "netflix", "outlook", "yahoo", "chatgpt", "claude", "perplexity",
    ]

    // MARK: - Text vs screen

    /// Positive signals that a turn doesn't need the screen.
    static func isClearlyTextOnly(_ text: String, context: Context) -> Bool {
        // If they're pointing at the screen ("this", "here", "click", a UI noun),
        // keep the screen — even if other signals also fire.
        if hasScreenDeixis(text) { return false }
        if isMath(text) { return true }
        if isFollowUpToText(text, context: context) { return true }
        if isGeneralKnowledge(text) { return true }
        return false
    }

    /// Words that mean "look at what's on my screen" or "point at it".
    static func hasScreenDeixis(_ text: String) -> Bool {
        let deictic = [
            "this", "here", "on screen", "on my screen", "on the screen",
            "where do i", "where should i", "where is the", "where's the", "where can i",
            "click", "highlight", "point at", "point to", "show me where",
            "what does this", "what's this", "read this", "this page",
            "screenshot", "cursor", "selected", "which button", "which one",
        ]
        // UI nouns strongly imply the screen ("the settings button", "that menu").
        let uiNouns = [" button", " menu", " icon", " toolbar", " field", " checkbox",
                       " dropdown", " text box", " text field", " slider", " the screen"]
        if deictic.contains(where: text.contains) { return true }
        if uiNouns.contains(where: text.contains) { return true }
        return false
    }

    /// Arithmetic, including follow-ups that operate on the last answer
    /// ("add two to that", "times that by ten").
    static func isMath(_ text: String) -> Bool {
        let hasDigit = text.contains(where: { $0.isNumber })
        // Symbolic operators between things (rare from speech, but cheap to check).
        if hasDigit && (text.contains(" + ") || text.contains(" * ")
                        || text.contains(" / ") || text.contains(" = ")) {
            return true
        }
        let mathWords = ["plus", "minus", "times", "multiplied", "divided", "divide",
                         "subtract", "add ", "sum of", "square root", "squared",
                         "percent", "percentage", "modulo", "to the power"]
        let hasMathWord = mathWords.contains(where: text.contains)
        if hasMathWord && (hasDigit || text.contains("that") || text.contains(" it")) {
            return true
        }
        return false
    }

    /// A short reference back to the previous answer, when that answer was a text
    /// turn (so "that"/"it" can't mean an on-screen element).
    static func isFollowUpToText(_ text: String, context: Context) -> Bool {
        guard context.hasConversationHistory, !context.previousTurnUsedScreen else { return false }
        let starters = ["and ", "also ", "what about", "how about", "then ", "ok ", "okay ",
                        "no ", "actually", "wait", "so ", "but ", "why", "and then"]
        if starters.contains(where: { text.hasPrefix($0) || text == $0.trimmingCharacters(in: .whitespaces) }) {
            return true
        }
        let backref = ["that", " it", "the last", "your answer", "previous", "again",
                       "the first one", "the second one"]
        if backref.contains(where: text.contains) { return true }
        return false
    }

    /// General-knowledge / creative questions that stand on their own.
    static func isGeneralKnowledge(_ text: String) -> Bool {
        let starters = ["what is ", "what's ", "whats ", "who is ", "who's ", "who was",
                        "when ", "why ", "how do ", "how does ", "how can ", "how to ",
                        "define ", "explain ", "tell me about", "what are ", "what does ",
                        "give me ", "write me", "write a ", "translate ", "summarize the",
                        "what's the difference", "can you explain", "help me understand",
                        "brainstorm", "suggest ", "recommend "]
        return starters.contains { text.hasPrefix($0) || text.contains($0) }
    }
}

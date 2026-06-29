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
    /// Capture the screen and *describe/answer* about it (the default vision
    /// model, e.g. Moondream). No coordinates expected.
    case screen
    /// Capture the screen and *point* at a UI element — the user asked where to
    /// click / find something. Routed to the grounding model (e.g. qwen2.5vl)
    /// which returns the pixel coordinates that fly the blue cursor.
    case screenPoint
    /// Capture the screen, ground a UI element, fly the cursor to it, **and
    /// actually click it** — the user told LocalClicky to click/press something
    /// ("click the submit button"), not just to show where it is.
    case screenClick
    case text
    case browserCommand
    /// Open / launch a local macOS application ("launch spotify", "open the
    /// notes app"). Handled by LocalAppLauncher.
    case openApp
    /// Copy the companion's last spoken answer to the clipboard ("copy your
    /// answer", "put that on my clipboard").
    case copyLastAnswer
    /// Show a concise, honest answer in the blue side-text beside the cursor
    /// ("give me X in text", "give text", "show me the text").
    case showText
    /// Answer a question that needs the live internet ("look it up online",
    /// "what's the latest…"). Fetches + synthesizes via WebReachTool. This is the
    /// one route that leaves the no-cloud guarantee, so it's narrowly triggered.
    case webReach
    /// Set + start a countdown timer ("set a timer for 4 minutes"). Handled by an
    /// in-app timer that speaks/notifies when it finishes.
    case setTimer
    /// Control the Spotify desktop app ("play despacito on spotify", "pause
    /// spotify", "next song on spotify"). Handled via the Spotify scripting bridge.
    case spotify
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

        // A "where do I click…/point at…" question — or an imperative "click the
        // X" — is about the screen, even when it mentions "open settings" or a
        // site name. Detect both first so the app/browser launcher can't hijack
        // them (e.g. "where do i click to open settings" must point, not launch
        // Settings; "click the new tab button" must click on screen, not open a
        // browser tab).
        let isClickCommand = wantsClick(text)
        let isPointingQuestion = isClickCommand || wantsPointing(text)

        // 1) Deterministic action requests win over questions, in order of how
        //    unambiguous they are — but never over a pointing/click request.
        //    a) "copy your answer to the clipboard" — refers to what we just said.
        if wantsCopyLastAnswer(text) { return .copyLastAnswer }
        //    a2) "give me X in text" / "give text" — answer in the blue side-text.
        if wantsShowText(text) { return .showText }
        if !isPointingQuestion {
            //    a3) "search X on my computer" / "google X" — search in the browser.
            //        Checked before web-reach so an explicit "google the weather"
            //        opens the browser instead of being read aloud.
            if ComputerActionPlanner.computerSearchQuery(from: text) != nil { return .browserCommand }
            //    a4) "look it up online" / "what's the weather" — fetch from the web
            //        and answer aloud. After the explicit-browser check above so
            //        "google X" wins, but before app/browser so "search the web and
            //        tell me" gets an answer instead of just opening a tab.
            if wantsWebReach(text) { return .webReach }
            //    a5) "set a timer for 4 minutes" — start a countdown.
            if ComputerActionPlanner.timerRequest(from: text) != nil { return .setTimer }
            //    a6) "play despacito on spotify" / "pause spotify" — control Spotify.
            //        Checked before openApp so "play X on spotify" controls the app
            //        instead of just launching it. ("open spotify" has no playback
            //        verb, so it still falls through to openApp.)
            if ComputerActionPlanner.spotifyAction(from: text) != nil { return .spotify }
            //    b) "launch spotify" / "open the notes app" — open an installed app.
            //       Checked before the browser so explicit app phrasing isn't read
            //       as a website (e.g. "launch spotify" opens the app, not the site).
            if AppCommandPlanner.isAppLaunch(text) { return .openApp }
            //    c) "open a new tab and go to gmail" — navigate the browser.
            if isBrowserCommand(text) { return .browserCommand }
        }

        // 2) No screen this turn (text-only mode, or no permission) → text path.
        guard context.visionModeSelected, context.screenAvailable else { return .text }

        // 3) Direct screen interactions: click an element, or point at one.
        if isClickCommand { return .screenClick }
        if isPointingQuestion { return .screenPoint }

        // 4) Be a normal assistant by DEFAULT, and only look at the screen when the
        //    user is actually referring to it ("this", "on screen", a highlighted
        //    selection, a UI element, "what am i looking at"). This is the key fix
        //    for "it just describes my screen on every question" — a plain question
        //    the user could ask any assistant ("what's the time", "tell me a joke")
        //    no longer triggers a screenshot + screen-grounded answer.
        if referencesScreen(text) { return .screen }
        return .text
    }

    // MARK: - Pointing / clicking / describing

    /// True when the user is telling LocalClicky to actually *click* (or press /
    /// tap / hit / select) something on screen — an imperative action, not a
    /// question about where something is. "where do i click" / "show me where"
    /// stay pointing (the user wants to be shown, not have it clicked for them).
    static func wantsClick(_ text: String) -> Bool {
        // Asking *where* / *how* is a pointing question, never an action.
        if text.contains("where") || text.contains("show me")
            || text.hasPrefix("how do i") || text.hasPrefix("how can i") {
            return false
        }
        let actionPhrases = [
            " click the", " click on", "click it", "click that", "click here",
            "press the", "press on", "tap the", "tap on", "hit the",
            "double click", "double-click", "go ahead and click", "can you click",
            "please click", "select the", "choose the",
        ]
        if actionPhrases.contains(where: text.contains) { return true }
        // Bare imperative at the very start: "click ...", "press ...", "tap ...".
        for verb in ["click ", "press ", "tap ", "hit "] where text.hasPrefix(verb) {
            return true
        }
        return false
    }

    /// True when the user wants the blue cursor to *point* at something on screen
    /// (where to click, find a button, etc.) rather than just hear it described.
    /// Tightly phrased so "what does this button do" stays a describe turn.
    static func wantsPointing(_ text: String) -> Bool {
        let pointingPhrases = [
            "point at", "point to", "point me", "point out", "point the",
            "show me where", "show me how to get to",
            "where do i", "where should i", "where can i", "where to click",
            "where is the", "where's the", "where is it", "where's it", "where are the",
            "how do i get to", "how do i find",
            "which button", "which one", "which icon", "which tab", "which option", "which menu",
            "highlight the", "highlight ",
        ]
        if pointingPhrases.contains(where: text.contains) { return true }
        // Imperative "click ..." that targets a UI element.
        if text.hasPrefix("click ") || text.contains(" click the") || text.contains(" click on")
            || text.contains("where do i click") {
            return true
        }
        // A UI noun paired with a find/locate/where cue.
        let uiNouns = [" button", " menu", " icon", " toolbar", " field", " checkbox",
                       " dropdown", " text box", " text field", " slider", " tab", " link", " option"]
        let locateCue = text.contains("find ") || text.contains("locate ") || text.contains("where")
        if locateCue && uiNouns.contains(where: text.contains) { return true }
        return false
    }

    /// True when the user is actually referring to what's on their screen — so we
    /// should look at it — rather than asking a self-contained question. This is
    /// what keeps LocalClicky from screenshotting + describing on every turn: the
    /// screen is used only on a positive reference to it.
    static func referencesScreen(_ text: String) -> Bool {
        if hasScreenDeixis(text) { return true }
        let screenIntents = [
            "what am i looking at", "what's on my", "whats on my", "what is on my",
            "on this page", "on the page", "this page", "this article", "this code",
            "this text", "this image", "this diagram", "this error", "this line",
            "this paragraph", "this selection", "my selection", "the highlighted",
            "what i'm reading", "what im reading", "summarize this", "explain this",
            "what is this", "what does this say", "translate this", "read this",
        ]
        return screenIntents.contains(where: text.contains)
    }

    // MARK: - Clipboard

    /// True when the user is asking to copy the companion's previous answer to the
    /// clipboard. Tightly phrased (it must reference the answer or name the
    /// clipboard) so an on-screen "copy this file" never triggers it.
    static func wantsCopyLastAnswer(_ text: String) -> Bool {
        // "... clipboard" paired with a copy/save verb.
        if text.contains("clipboard"),
           text.contains("copy") || text.contains("put ") || text.contains("save")
            || text.contains("stick ") || text.contains("add ") {
            return true
        }
        // Phrases that explicitly reference the assistant's answer.
        let answerPhrases = [
            "copy your answer", "copy the answer", "copy that answer",
            "copy your response", "copy that response", "copy your reply",
            "copy your last answer", "copy your message", "copy your last message",
            "copy what you said", "copy what you just said", "copy that down",
        ]
        return answerPhrases.contains(where: text.contains)
    }

    // MARK: - "Give text" (answer in the blue side-text)

    /// True when the user wants the answer shown as text beside the cursor rather
    /// than (only) spoken: "give me X in text", "give text", "show me the text".
    static func wantsShowText(_ text: String) -> Bool {
        if text == "give text" || text.hasPrefix("give text ") || text.hasPrefix("give me text") { return true }
        let phrases = [
            " in text", " as text", " in writing", " on text",
            "show me the text", "show it in text", "put it in text", "type it out",
            "write it out", "give me the text", "text it to me", "text me the",
        ]
        return phrases.contains(where: text.contains)
    }

    // MARK: - Web reach (the one internet-answering route)

    /// True when the user clearly wants info *from the live internet* answered
    /// back to them (not just a site opened). Conservative on purpose — this is
    /// the only route that leaves the no-cloud guarantee, so it must require an
    /// explicit internet marker, never fire on a plain local question.
    static func wantsWebReach(_ text: String) -> Bool {
        // Explicit "use the internet" phrasing.
        let explicitMarkers = [
            "online", "on the internet", "on the web", "from the web", "from the internet",
            "the latest", "latest news", "what's new with", "whats new with",
            "what does the internet say", "search the internet", "search the web and",
            "look it up online", "look that up online", "look this up online",
            "check the web", "check online", "google it and tell", "according to the internet",
        ]
        if explicitMarkers.contains(where: text.contains) { return true }

        // High-confidence "needs live data" questions that essentially always
        // require the internet and almost never refer to the screen or to general
        // knowledge a small local model already has. Kept tight to avoid wrongly
        // leaving the no-cloud guarantee on a casual question.
        let liveDataMarkers = [
            "weather", "forecast", "temperature outside",
            "stock price", "share price", "stock market", "price of ", "how much is ",
            "how much does ", " cost right now", "exchange rate", "how much are ",
            "who won the", "what was the score", "the final score", "the score of",
            "headlines", "in the news", "news about", "news on",
            "currently the president", "current president", "who is the president",
        ]
        return liveDataMarkers.contains(where: text.contains)
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

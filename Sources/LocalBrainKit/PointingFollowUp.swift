//
//  PointingFollowUp.swift
//  LocalBrainKit
//
//  "Point out to me again" after "point out the chat window". A pointing turn sends no history (the measured
//  request has none; history brought back a refusal the model then repeated), so on its own the follow-up
//  names nothing and the model points at whatever it likes. The app keeps the noun phrase of the last
//  pointing or click request; when a new pointing turn has no object of its own, that phrase is put back
//  into the words sent to the model. History stays off. A new object replaces the stored one.
//
//  Pure: the manager owns the stored phrase and the call.
//

import Foundation

public enum PointingFollowUp {
    /// What a pointing turn's words become and what the app remembers for the next one.
    public struct Resolution: Equatable, Sendable {
        /// The words to send to the model, and to decide the window line on.
        public let transcript: String
        /// The stored object that was put into the words, nil when the turn had its own object or none was stored.
        public let substitutedObject: String?
        /// The object to store: this turn's own, else the one already stored.
        public let object: String?
    }

    public static func resolve(transcript: String, lastObject: String?) -> Resolution {
        if let own = object(in: transcript) {
            return Resolution(transcript: transcript, substitutedObject: nil, object: own)
        }
        guard isFollowUp(transcript), let lastObject else {
            return Resolution(transcript: transcript, substitutedObject: nil, object: lastObject)
        }
        let text = transcript.lowercased()
        let verb = text.range(of: #"\b(?:click|press|tap|hit)\b"#, options: .regularExpression) != nil ? "click" : "point out"
        return Resolution(transcript: "\(verb) \(lastObject)", substitutedObject: lastObject, object: lastObject)
    }

    /// The noun phrase of a pointing or click request, with an article: "the chat window", or nil when the
    /// words name nothing ("point out to me again", "point to it", "that one").
    public static func object(in transcript: String) -> String? {
        let text = transcript.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9' -]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let patterns = [
            // "where the chat window is" (the object sits before is/are)
            #"\bwhere ((?:the|my|that|this) .+?) (?:is|are)\b"#,
            // "where is the chat window", "where's the send button"
            #"\bwhere(?: is|'s| are) (.+)$"#,
            #"\b(?:point out|point to|point at|point me to|point the|find out|find|locate|show me|show|highlight|click on|click|press|tap|hit|select|choose) (?:where )?(?:out )?(.+)$"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            if let phrase = clean(String(text[range])) { return phrase }
        }
        return nil
    }

    /// True for words that ask to point or click again with no object of their own: "point out to me again",
    /// "point to it", "show me again", "click it", "again", "that one". `object(in:)` is nil for all of them.
    public static func isFollowUp(_ transcript: String) -> Bool {
        object(in: transcript) == nil && isBareFollowUp(transcript)
    }

    /// The closed list of follow-up phrasings. Only a turn after a pointing turn treats the ones with no
    /// pointing word ("again", "that one") as pointing (ConversationRouter.Context.previousTurnWasPointing).
    public static func isBareFollowUp(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
            .replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let pattern = #"^(?:(?:ok|okay|hey|so|and) )?(?:please )?(?:(?:can|could) you )?(?:(?:point(?: it| that| this)?(?: out| to| at)?|show|find|click|press|tap)(?: it| that| that one| this one| the one| me| me it| me that one| me this one| it to me| out)?(?: to me| for me)?(?: again| one more time| once more)?|again|one more time|once more|that one|this one|the one)(?: please)?$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static let tails = [" to me", " for me", " please", " again", " right now", " now", " there", " located", " one more time", " once more"]
    private static let notAnObject: Set<String> = ["it", "that", "this", "them", "those", "these", "one", "that one", "this one",
                                                   "the one", "me", "out", "there", "here", "again", "to me"]

    /// Trailing politeness and "again" off, an article on, and nil for a pronoun or a purpose clause ("to save").
    private static func clean(_ raw: String) -> String? {
        var phrase = raw.trimmingCharacters(in: .whitespaces)
        var trimmed = true
        while trimmed {
            trimmed = false
            for tail in tails where phrase.hasSuffix(tail) {
                phrase = String(phrase.dropLast(tail.count))
                trimmed = true
            }
        }
        phrase = phrase.trimmingCharacters(in: .whitespaces)
        for lead in ["out ", "to me ", "me "] where phrase.hasPrefix(lead) { phrase = String(phrase.dropFirst(lead.count)) }
        guard !phrase.isEmpty, !notAnObject.contains(phrase),
              !phrase.hasPrefix("to ") && !phrase.hasPrefix("so ") && !phrase.hasPrefix("in order") else { return nil }
        let articles = ["the ", "a ", "an ", "my ", "that ", "this ", "your ", "our "]
        return articles.contains(where: phrase.hasPrefix) ? phrase : "the " + phrase
    }
}

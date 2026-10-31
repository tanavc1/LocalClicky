//
//  InkTurnPolicy.swift
//  LocalBrainKit
//
//  What an ink describe turn sends. Naming ("what is this?") is the one
//  measured request: the eval's A1FPC text on the 9B, byte for byte, with no
//  history and no Accessibility block. Every other question about a marked
//  area ("go into detail", "what does this say") is an explain turn: it keeps
//  the images and the mark line, and adds the Accessibility block and history
//  so the answer can quote the exact words and numbers that are there.
//  Nothing here touches the naming request.
//

import Foundation

public enum InkQuestionKind: Equatable, Sendable { case naming, explain }

public struct InkTurnPlan: Equatable, Sendable {
    public let kind: InkQuestionKind
    /// The X-Clicky-Turn value. Naming keeps the measured 9B route; explain names itself for the log and goes to Holo35.
    public let turnHeader: String
    /// False for naming (A1FPC), true for explain.
    public let sendsAccessibilityBlock: Bool
    /// False for naming (the measured request has none), true for explain.
    public let sendsHistory: Bool
}

public enum InkTurnPolicy {
    /// Nil when the turn is not an ink describe turn (no usable ink, or the words ground: point, click, draw).
    public static func plan(transcript: String, hasUsableInk: Bool, wantsGrounding: Bool) -> InkTurnPlan? {
        guard hasUsableInk, !wantsGrounding else { return nil }
        switch InkQuestion.kind(transcript) {
        case .naming:
            return InkTurnPlan(kind: .naming, turnHeader: OllamaClient.inkDescribeTurn,
                               sendsAccessibilityBlock: false, sendsHistory: false)
        case .explain:
            return InkTurnPlan(kind: .explain, turnHeader: OllamaClient.inkExplainTurn,
                               sendsAccessibilityBlock: true, sendsHistory: true)
        }
    }

    /// Whether earlier exchanges ride along. A grounding turn never sends them
    /// (the measured pointing request has none); an ink turn follows its plan.
    public static func sendsHistory(wantsGrounding: Bool, plan: InkTurnPlan?) -> Bool {
        !wantsGrounding && (plan?.sendsHistory ?? true)
    }
}

public enum InkQuestion {
    /// Naming is the narrow case ("what is this?", "this?", "name this"); every
    /// other question about a marked area is an explain turn. Words that say
    /// nothing but "this" (an empty question after the filler is dropped) name.
    public static func kind(_ transcript: String) -> InkQuestionKind {
        let text = normalised(transcript)
        if text.isEmpty { return .naming }
        return namingPatterns.contains { text.range(of: $0, options: .regularExpression) != nil } ? .naming : .explain
    }

    /// Lowercase, curly apostrophes straightened, anything but a to z, an
    /// apostrophe or a space turned into a space, spaces collapsed, filler words dropped.
    static func normalised(_ transcript: String) -> String {
        let straightened = transcript.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let letters = String(straightened.map { ($0 >= "a" && $0 <= "z") || $0 == "'" ? $0 : " " })
        return letters.split(separator: " ").filter { !fillerWords.contains(String($0)) }.joined(separator: " ")
    }

    private static let fillerWords: Set<String> = [
        "hey", "hi", "ok", "okay", "so", "um", "uh", "please", "just", "quickly", "clicky", "localclicky", "local",
    ]

    private static let namingPatterns: [String] = [
        #"^(?:(?:can|could|would|will) you )?what(?:'s| is|s) (?:this|that|it)(?: (?:one|thing|here|right here|there|called|exactly|thing here|button|icon|control|option|item|row|word))?$"#,
        #"^(?:(?:can|could|would|will) you )?tell me what (?:this|that|it) is(?: called)?$"#,
        #"^do you know what (?:this|that|it) is$"#,
        #"^what am i looking at(?: here)?$"#,
        #"^(?:this|that)(?: one| thing)?$"#,
        #"^name (?:this|that|it)$"#,
        #"^(?:what|which) (?:button|icon|control|thing|option|item|row|word) is (?:this|that)$"#,
    ]
}

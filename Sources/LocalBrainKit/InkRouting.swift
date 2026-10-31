//
//  InkRouting.swift
//  LocalBrainKit
//
//  How drawing changes the route. A turn with usable ink is about the screen,
//  whatever the words say, so ink beats the browser, app, timer and other
//  action keywords. It only becomes a pointing or clicking turn when the
//  words themselves ask to point or click; otherwise it is a describe turn
//  ("what is this?" with a circle drawn). With no ink, or when the screen is
//  unavailable, the normal router decides.
//

import Foundation

public enum InkRouting {
    public static func route(transcript: String,
                             context: ConversationRouter.Context,
                             hasUsableInk: Bool) -> ConversationRoute {
        let base = ConversationRouter.route(transcript: transcript, context: context)
        guard hasUsableInk, context.visionModeSelected, context.screenAvailable else { return base }

        let text = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ConversationRouter.wantsClick(text) { return .screenClick }
        if ConversationRouter.wantsPointing(text) { return .screenPoint }
        return .screen
    }
}

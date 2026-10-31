//
//  DrawingRouting.swift
//  LocalBrainKit
//
//  The route for a turn where the user asks the assistant to draw: circle,
//  outline, underline, highlight or mark something, or "show me where". It
//  wraps InkRouting (which wraps ConversationRouter) and only changes its
//  answer when drawing is enabled, the screen is available, and the words ask
//  for a mark, or for a figure that marks nothing (a sketch), or to clear what
//  was drawn. With drawing off the result is exactly InkRouting's.
//
//  The trigger is deliberately phrase-shaped, not a bare word list: "mark",
//  "draw" and "circle" are also ordinary words ("bookmark", "a drawer",
//  "the circle of fifths"). A click command always wins ("click the button i
//  circled" clicks), and an action route (browser, app, timer, and so on) is
//  never taken over.
//

import Foundation

public enum DrawingIntent {
    /// True when the words ask the assistant to mark something on the screen.
    public static func wantsDrawing(_ transcript: String) -> Bool {
        let text = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("show me where") { return true }
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
            && !isMarkAsStatus(text)
    }

    private static let objects = "(?:the|this|that|these|those|it|them|all|each|every|my|where|around)"

    private static let patterns: [String] = [
        // circle / underline / highlight / mark + an object
        #"\b(?:circle|underline|highlight)\s+\#(objects)\b"#,
        #"\bmark\s+(?:the|this|that|these|those|it|them|where|each|every)\b"#,
        // "outline" is also a noun (outline the essay), so only the pronouns
        // and "draw an outline" count.
        #"\boutline\s+(?:this|that|it|them|these|those)\b"#,
        // draw + a mark word somewhere after it, or draw on the screen
        #"\bdraw\b.*\b(?:around|arrow|box|circle|rectangle|line|underline|ring|border|outline)\b"#,
        #"\bdraw\s+(?:on|over)\s+(?:the|this|my)\b"#,
        #"\bdraw\s+(?:it|that|this)\b"#,
    ]

    /// "mark it as read", "mark this done": a status change, not a drawing.
    private static func isMarkAsStatus(_ text: String) -> Bool {
        let statuses = "read|unread|done|complete|completed|spam|junk|seen|finished"
        return text.range(of: #"\bmark\b.*\bas\s+(?:\#(statuses))\b"#, options: .regularExpression) != nil
            || text.range(of: #"\bmark\s+(?:it|this|that|them|these|those|all)\s+(?:\#(statuses))\b"#,
                          options: .regularExpression) != nil
    }
}

public enum DrawingRouting {
    public static func route(transcript: String,
                             context: ConversationRouter.Context,
                             hasUsableInk: Bool,
                             drawingEnabled: Bool) -> ConversationRoute {
        let base = InkRouting.route(transcript: transcript, context: context, hasUsableInk: hasUsableInk)
        guard drawingEnabled, context.visionModeSelected, context.screenAvailable else { return base }
        let text = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ClearMarksIntent.wants(text) { return .clearMarks }
        guard base == .screen || base == .screenPoint || base == .text else { return base }
        guard !ConversationRouter.wantsClick(text) else { return base }
        // A sketch is tested before the marks: DrawingIntent matches "draw ... box|arrow|circle"
        // and would turn "draw a box in the middle of the screen" into a mark of some control.
        if SketchIntent.figure(text) != nil { return .screenSketch }
        guard DrawingIntent.wantsDrawing(text) else { return base }
        return .screenDraw
    }
}

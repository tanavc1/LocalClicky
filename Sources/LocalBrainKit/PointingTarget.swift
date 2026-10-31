//
//  PointingTarget.swift
//  LocalBrainKit
//
//  What a pointing or click request is asking to find. The point prompt speaks
//  of one control ("click the settings gear"), so a request for a whole window
//  or app ("point out where the chat window is") gets one extra user-turn line,
//  LocalPrompts.windowTargetLine. The system prompt stays as measured; only a
//  request that names a window or an app and no control carries the line.
//

import Foundation

public enum PointingTarget {
    /// True when a pointing or click request names a window or app (or a window's
    /// title bar) as the thing to find, and no control noun. "where is the save
    /// button in this app" is a control inside an app, so it is false.
    public static func namesWindow(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        guard text.range(of: windowObject, options: .regularExpression) != nil
                || text.range(of: titleBar, options: .regularExpression) != nil else { return false }
        // "title bar" names a window, so it is taken out before the control nouns (one of which is "bar").
        let withoutTitleBar = text.replacingOccurrences(of: titleBar, with: " ", options: .regularExpression)
        return withoutTitleBar.range(of: controlNoun, options: .regularExpression) == nil
    }

    /// Whether the user turn carries `LocalPrompts.windowTargetLine`: a pointing or click turn, or a draw turn
    /// that is drawn from a point (it sends the point prompt too), whose words name a window or app.
    public static func wantsWindowLine(transcript: String, wantsPointing: Bool, pointDrawKind: PointDrawKind?) -> Bool {
        (wantsPointing || pointDrawKind != nil) && namesWindow(transcript)
    }

    /// The article is optional ("point out chat window", "point out claude window"): the word itself is the cue.
    private static let windowObject = #"\b(?:window|app|application)s?\b"#
    /// "title bar" is a window cue, not a control noun: "point at the title bar of the chat window" asks for the
    /// window, and the window snap lands on its title bar.
    private static let titleBar = #"\btitle ?bars?\b"#
    /// "the chat window bar" is a control request: bar, box, input, composer, text field, search bar and sidebar
    /// count as controls. "menu bar" therefore does too, on purpose: asking for the bar is asking for a control,
    /// and the point prompt handles one control well.
    private static let controlNoun = #"\b(?:button|menu|icon|toolbar|field|checkbox|dropdown|slider|tab|link|option|text box|dock|bar|box|input|composer|text field|search bar|sidebar)s?\b"#
}

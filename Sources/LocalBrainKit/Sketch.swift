//
//  Sketch.swift
//  LocalBrainKit
//
//  A sketch turn: "draw tic tac toe on the screen", "draw a smiley face". The
//  drawing marks nothing, so it is not a mark turn. The app composes every named
//  figure itself (SketchTemplate), in screenshot pixels, so there is no model
//  call and no coordinate risk; the model writes tags only for a figure with no
//  template (SketchFigure.freeform), and that path can be turned off with
//  SketchLimits.freeformEnabled. Only reachable while drawing is on, through
//  DrawingRouting.
//
//  SketchIntent returns nil whenever the words name something on the screen to
//  draw at ("around the error", "to the menu", "it"): those stay mark turns.
//

import CoreGraphics
import Foundation

public enum SketchFigure: Equatable, Sendable {
    case ticTacToe, box, line, arrow, circle, triangle, star, smiley, cross, check
    /// "a house", "a flowchart with three boxes": no template, the model draws it.
    case freeform(String)
}

public enum SketchLimits {
    /// One switch for the model-written path. When false, a figure with no template
    /// is answered with SketchTemplate.unsupportedSentence and no model call.
    public static let freeformEnabled = true
    /// The most tags a freeform sketch may draw.
    public static let maxTags = 8
    /// The prompt asks for no more than this many tokens: 8 tags and one sentence.
    public static let freeformAnswerMaxTokens = 400
    /// Spoken when the model's reply holds no valid tag.
    public static let failureSentence = "i could not draw that one."

    /// Spoken when tags closed but the reply holds no sentence (the prompt asks for one; a screen reader user needs it).
    public static let drawnSentence = "here is the drawing, in the middle of your screen."

    /// What a freeform sketch speaks: the failure sentence with no valid tag, else the reply's own words with
    /// every complete tag removed and a tag cut off by the token cap dropped, else `drawnSentence`.
    public static func spokenSentence(in reply: String, closedTags: Int) -> String {
        guard closedTags > 0 else { return failureSentence }
        let words = ShapeTagParser.stripAllTags(from: reply)
            .replacingOccurrences(of: #"\[[^\[\]]*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? drawnSentence : words
    }

    /// Whether a freeform sketch may draw this tag: shapes only (the prompt has no HIGHLIGHT) and at most `maxTags`.
    public static func admits(_ drawing: InkDrawing, alreadyClosed: Int) -> Bool {
        guard case .shape = drawing else { return false }
        return alreadyClosed < maxTags
    }
}

public enum SketchHistory {
    /// What a sketch turn records in the conversation history instead of the sentence it spoke. A later
    /// chat turn that finds "here is a tic tac toe board ... with an x in the centre" in its history
    /// recites it for a drawing that does not exist; a neutral note leaves nothing to recite.
    public static func note(for figure: SketchFigure, drew: Bool = true) -> String {
        let name: String
        switch figure {
        case .ticTacToe: name = "a tic tac toe board"
        case .box: name = "a box"
        case .line: name = "a line"
        case .arrow: name = "an arrow"
        case .circle: name = "a circle"
        case .triangle: name = "a triangle"
        case .star: name = "a star"
        case .smiley: name = "a smiley face"
        case .cross: name = "a cross"
        case .check: name = "a check mark"
        case .freeform(let phrase): name = (phrase.first.map { "aeiou".contains($0) } ?? false ? "an " : "a ") + phrase
        }
        return drew ? "(drew \(name))" : "(tried to draw \(name))"
    }
}

public enum SketchTiming {
    /// A sketch is the point of its turn, so it stays this long after the speech
    /// (a mark that accompanies a sentence holds 1.5 s). A key press or "clear that" ends it sooner.
    public static let holdSeconds: Double = 10
}

/// Where on the screen a template figure goes: one of nine regions, row-major.
public enum SketchAnchor: Int, Equatable, Sendable, CaseIterable {
    case topLeft, top, topRight, left, centre, right, bottomLeft, bottom, bottomRight

    /// 0 for the left column, 2 for the right.
    public var column: Int { rawValue % 3 }
    /// 0 for the top row, 2 for the bottom.
    public var row: Int { rawValue / 3 }

    /// The region's name as it is spoken: also the name of a tic tac toe cell.
    public var name: String {
        ["top left", "top", "top right", "left", "centre", "right", "bottom left", "bottom", "bottom right"][rawValue]
    }

    /// "in the bottom left of your screen": where the spoken sentence says the figure is.
    public var spokenPlace: String {
        switch self {
        case .centre: return "in the middle of your screen"
        case .top, .bottom: return "at the \(name) of your screen"
        case .left, .right: return "on the \(name) of your screen"
        default: return "in the \(name) of your screen"
        }
    }

    /// "top left", "bottom", "upper right", "middle", "centre left", "top-right hand": nil for no region word.
    static func parse(region words: String) -> SketchAnchor? {
        let tokens = words.lowercased().split(whereSeparator: { !$0.isLetter })
        var vertical: Int?, horizontal: Int?, found = false
        for token in tokens {
            switch token {
            case "top", "upper": vertical = 0; found = true
            case "bottom", "lower": vertical = 2; found = true
            case "left": horizontal = 0; found = true
            case "right": horizontal = 2; found = true
            case "middle", "centre", "center": found = true
            default: break
            }
        }
        guard found else { return nil }
        return SketchAnchor(rawValue: (vertical ?? 1) * 3 + (horizontal ?? 1))
    }
}

/// How big a template figure is drawn: "a small star", "a big arrow".
public enum SketchSize: Equatable, Sendable {
    case small, normal, large

    /// Multiplies the figure's size (a fraction of the screenshot's shorter side).
    public var scale: Double {
        switch self {
        case .small: return 0.6
        case .normal: return 1
        case .large: return 1.5
        }
    }
}

/// What a sketch request asks for. Placement and size apply to template figures only; a freeform
/// figure is drawn by the model, whose prompt has neither, so it stays in the middle at the usual size.
public struct SketchRequest: Equatable, Sendable {
    public let figure: SketchFigure
    public let anchor: SketchAnchor
    public let size: SketchSize
    /// Tic tac toe only: 9 cells, row-major (`SketchTemplate.emptyBoard` otherwise).
    public let board: String

    public init(figure: SketchFigure, anchor: SketchAnchor = .centre, size: SketchSize = .normal,
                board: String = SketchTemplate.emptyBoard) {
        self.figure = figure
        self.anchor = anchor
        self.size = size
        self.board = board
    }
}

public enum SketchIntent {
    /// The figure the words ask to draw, or nil when they do not ask for a sketch.
    public static func figure(_ transcript: String) -> SketchFigure? { parse(transcript)?.figure }

    /// The whole request: figure, placement, size and (tic tac toe) the board. Nil when the words do not ask
    /// for a sketch. draw, sketch and doodle also reach a freeform figure; put, place, make, show me, give me,
    /// add and create reach a figure only when the whole object after the verb is a template figure (the name,
    /// then at most a board word, a placement, a size or a tic tac toe move), so "make a note", "add a reminder"
    /// and "show me the box score" are never sketches.
    public static func parse(_ transcript: String) -> SketchRequest? {
        var text = transcript.lowercased()
        // "draw up", "draw conclusions" and "draw attention" are not drawing.
        guard text.range(of: #"\bdraw\s+(?:up|conclusions?|attention)\b"#, options: .regularExpression) == nil else { return nil }

        // Tic tac toe words come first: a move ("x in the centre") holds a region word the placement
        // patterns would otherwise strip, and "an x on the left" holds a target cue.
        var moves: [(mark: Character, cell: Int)] = []
        let mentionsBoard = text.range(of: ticTacToeWords + #"|noughts and crosses"#, options: .regularExpression) != nil
        if mentionsBoard {
            let (rest, found) = extractMoves(text)
            text = rest
            moves = found
        }
        let emptyBoard = mentionsBoard && text.range(of: emptyCue, options: .regularExpression) != nil
        let demoBoard = mentionsBoard && text.range(of: demoCue, options: .regularExpression) != nil
        // "nothing in it" holds a target cue ("it"); the board cues have said what they had to.
        if mentionsBoard { text = text.replacingOccurrences(of: emptyCue, with: " ", options: .regularExpression) }

        var anchor: SketchAnchor?
        for pattern in anchorPatterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                anchor = anchor ?? SketchAnchor.parse(region: String(text[range]))
            }
        }
        for pattern in placements {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        var size = SketchSize.normal
        if let range = text.range(of: #"\b(?:small|tiny|little|big|large|huge)\b"#, options: .regularExpression) {
            size = ["small", "tiny", "little"].contains(String(text[range])) ? .small : .large
        }
        text = text.replacingOccurrences(of: #"\b(?:big|large|huge|small|tiny|little|quick|simple)\b"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\bfor me\b|\bme\b"#, with: " ", options: .regularExpression)
        // A target cue means the words draw at something on the screen: a mark turn.
        guard targetCues.allSatisfy({ text.range(of: $0, options: .regularExpression) == nil }) else { return nil }

        let verbs = (try? NSRegularExpression(pattern: #"\b(draw|sketch|doodle|put|place|make|show|give|add|create)\b"#))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        for verb in verbs {
            guard let verbRange = Range(verb.range, in: text) else { continue }
            let drawing = ["draw", "sketch", "doodle"].contains(String(text[verbRange]))
            let afterVerb = text[verbRange.upperBound...].replacingOccurrences(of: #"[^a-z' -]"#, with: " ", options: .regularExpression)
            var words = afterVerb.split(separator: " ").map(String.init)
            while let first = words.first, ["a", "an", "the", "some", "of", "up"].contains(first) { words.removeFirst() }
            guard !words.isEmpty else { if drawing { return nil } else { continue } }
            let phrase = words.prefix(4).joined(separator: " ")
            let whole = words.joined(separator: " ")
            var figure: SketchFigure?
            var figureRange: Range<String.Index>?
            for (pattern, candidate) in named {
                if let range = whole.range(of: pattern, options: .regularExpression) {
                    figure = candidate
                    figureRange = range
                    break
                }
            }
            if figure == nil, drawing { figure = .freeform(phrase) }
            // The other verbs need the whole object to be the figure ("show me the star wars trailer" and
            // "show me the box score" are not sketches): the name, then at most a board word.
            if !drawing, let figureRange,
               !isFigureNameAlone(after: whole[figureRange.upperBound...], dropping: mentionsBoard ? demoCue : nil) { continue }
            // "show me the circle of fifths" is not a request for a circle.
            if !drawing, words.dropFirst().contains("of") { continue }
            guard let figure else { continue }
            var board = emptyBoardString
            if figure == .ticTacToe, !emptyBoard {
                if !moves.isEmpty {
                    var cells = Array(emptyBoardString)
                    for move in moves { cells[move.cell] = move.mark }
                    board = String(cells)
                } else if demoBoard {
                    board = SketchTemplate.demoBoard
                }
            }
            return SketchRequest(figure: figure, anchor: anchor ?? .centre, size: size, board: board)
        }
        return nil
    }

    private static let emptyBoardString = SketchTemplate.emptyBoard

    /// Words that may follow a figure name and still be that figure ("tic tac toe board", "smiley face"), and the
    /// connectors left behind where a placement or a move was taken out ("a tic tac toe with an x in the middle").
    private static let figureTrailers: Set<String> = ["board", "grid", "game", "face", "mark", "shape"]
    private static let connectors: Set<String> = ["with", "and", "then", "a", "an", "the"]

    /// True when nothing but a trailer or connector word follows the figure name. `cue` is a pattern for further
    /// board words to ignore (the demo board cue).
    private static func isFigureNameAlone(after tail: Substring, dropping cue: String?) -> Bool {
        var rest = String(tail)
        if let cue { rest = rest.replacingOccurrences(of: cue, with: " ", options: .regularExpression) }
        return rest.split(separator: " ").allSatisfy { figureTrailers.contains(String($0)) || connectors.contains(String($0)) }
    }

    /// "tic tac toe", "tic-tac-toe", "tictac", "tick tack toe": speech to text writes it every way.
    static let ticTacToeWords = #"ti[ck]{1,2}[ -]?ta[ck]{1,2}(?:[ -]?toes?)?"#

    /// "empty", "blank", "nothing in it": the board is drawn with no moves, whatever else the words say.
    private static let emptyCue = #"\b(?:empty|blank|clean|nothing in (?:it|there|them)|nothing filled in|nothing on it|no moves|no xs|no marks|without (?:any )?(?:moves|xs|marks))\b"#
    /// The old demo board only comes back behind one of these.
    private static let demoCue = #"\b(?:game in progress|in progress|some moves|some xs and os|partly (?:filled|played)|half (?:filled|finished|played))\b"#

    /// A region word of a position: "top left", "upper right hand", "bottom", "centre left", "left", "middle".
    private static let region = #"(?:(?:top|upper|bottom|lower)(?:[ -]+(?:left|right|middle|centre|center))?|(?:middle|centre|center)[ -]+(?:left|right)|left|right|middle|centre|center)(?:[ -]+hand)?"#

    /// A mark word then a region: "an x in the center", "o top left", "a nought in the bottom right corner".
    private static let move = #"\b(?:an?\s+)?(x|ex|cross|o|oh|nought|zero)\s+(?:(?:in|on|at)\s+)?(?:the\s+)?("# + region + #")\b(?:\s+(?:cell|square|box|spot|corner))?"#

    /// The text without its moves, and the moves in the order spoken (a later move into the same cell wins).
    private static func extractMoves(_ text: String) -> (String, [(mark: Character, cell: Int)]) {
        guard let expression = try? NSRegularExpression(pattern: move) else { return (text, []) }
        let whole = NSRange(text.startIndex..., in: text)
        var found: [(mark: Character, cell: Int)] = []
        for match in expression.matches(in: text, range: whole) {
            guard let markRange = Range(match.range(at: 1), in: text), let regionRange = Range(match.range(at: 2), in: text),
                  let anchor = SketchAnchor.parse(region: String(text[regionRange])) else { continue }
            found.append((["x", "ex", "cross"].contains(String(text[markRange])) ? "X" : "O", anchor.rawValue))
        }
        return (expression.stringByReplacingMatches(in: text, range: whole, withTemplate: " "), found)
    }

    /// Patterns whose text names the region, tried in order. A region word alone is not enough ("a right
    /// arrow"): it needs a preposition, a corner or side word, or the two-word form ("bottom left").
    private static let anchorPatterns: [String] = [
        #"\b(?:in|on|at|into|onto|across|over)\s+(?:the\s+|my\s+|a\s+)?"# + region
            + #"(?:\s+(?:corner|side|part|edge|half|area))?(?:\s+of\s+(?:the|my)\s+(?:screen|display|desktop|monitor))?"#,
        #"\b(?:top|upper|bottom|lower)[ -]+(?:left|right)\b(?:[ -]+hand)?(?:\s+(?:corner|side))?"#,
    ]

    /// Where on the screen: not targets, so they are dropped before the cue check.
    private static let placements: [String] = anchorPatterns + [
        #"\b(?:in|on|at|across|over|onto|to)\s+(?:the|my)\s+(?:screen|display|desktop|monitor|corner)\b"#,
        #"\bof\s+(?:the|my)\s+(?:screen|display|desktop|monitor)\b"#,
    ]

    private static let targetCues: [String] = [
        #"\b(?:it|this|that|them|these|those|here)\b"#,
        #"\b(?:around|under|underneath|over|above|below|beside|next to|near|at|to|toward|towards|through|on|onto|pointing (?:at|to))\s+(?:the|this|that|my|those|these|it|them)\b"#,
        #"\b(?:button|menu|icon|field|tab|link|word|line of|error|title|total|price|name)\b"#,
    ]

    /// The head of the phrase after the verb decides the figure; anything else is freeform for a draw verb.
    private static let named: [(String, SketchFigure)] = [
        (#"^(?:"# + ticTacToeWords + #"|noughts and crosses|grid)\b"#, .ticTacToe),
        (#"^(?:box|square|rectangle)\b"#, .box),
        (#"^line\b"#, .line),
        (#"^arrow\b"#, .arrow),
        (#"^(?:circle|ring)\b"#, .circle),
        (#"^triangle\b"#, .triangle),
        (#"^star\b"#, .star),
        (#"^(?:smiley|happy face|face)\b"#, .smiley),
        (#"^(?:cross|x)\b"#, .cross),
        (#"^(?:check ?mark|check|tick)\b"#, .check),
    ]
}

public enum ClearMarksIntent {
    /// "clear that", "erase the drawing", "wipe the board", "clear the tic tac toe", "erase the star". False for
    /// a clear that is about something else ("clear my inbox", "clear the cache"), and for a bare "that" after
    /// remove, undo or get rid of ("undo that" after a click turn undoes nothing that was drawn): those verbs
    /// need a drawing object. A figure name counts as an object, with or without "board"/"grid"/"game" after it;
    /// a figure other than tic tac toe needs "the", "that" or "your" before it ("clear the star").
    public static func wants(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        let drawing = "the screen|that drawing|the drawings?|your drawings?|the sketch|the marks|your marks|what you drew|the board|the grid"
        let figures = "box|square|rectangle|line|arrow|circle|ring|triangle|star|smiley(?: face)?|happy face|face|cross|check ?mark|tick"
        let tail = #"(?:\s+(?:please|now|again|for me))?[\s.!?]*$"#
        let verb = #"\b(?:clear|erase|wipe|remove|get rid of|undo)\s+(?:all\s+)?(?:of\s+)?"#
        let withObject = verb + #"(?:\#(drawing))"# + tail
        let ticTacToe = verb + #"(?:(?:the|that|your|my)\s+)?\#(SketchIntent.ticTacToeWords)(?:\s+(?:board|grid|game|drawing|sketch))?"# + tail
        let namedFigure = verb + #"(?:the|that|your)\s+(?:\#(figures))(?:\s+(?:drawing|sketch|figure))?"# + tail
        let bareThat = #"\b(?:clear|erase|wipe)\s+that"# + tail
        return [withObject, ticTacToe, namedFigure, bareThat].contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

/// What the app draws for a template figure: the marks, in screenshot pixels, and the one sentence
/// that says what they are (the whole content for someone who cannot see the screen).
public struct SketchPlan: Equatable, Sendable {
    public let drawings: [InkDrawing]
    public let spokenSentence: String

    public init(drawings: [InkDrawing], spokenSentence: String) {
        self.drawings = drawings
        self.spokenSentence = spokenSentence
    }
}

public enum SketchTemplate {
    /// The tic tac toe board's side, as a fraction of the shorter side of the screenshot (at the normal size).
    public static let sideFraction = 0.5
    /// The side or span of the other figures, as a fraction of the shorter side.
    public static let figureFraction = 0.35
    /// How far a figure's farthest point is from its centre, as a fraction of the (scaled) shorter side,
    /// for every figure but the board (the star's points and the line's ends are the farthest).
    static let figureReach = 0.2
    /// The gap kept between a figure placed in a region and the screen's edge, as a fraction of the shorter side.
    static let edgeMargin = 0.05
    /// 9 cells, row-major: no moves. The board of a plain request.
    public static let emptyBoard = "........."
    /// 9 cells, row-major: O top left, X centre, X bottom right. Only for "a game in progress" and the like.
    public static let demoBoard = "O...X...X"
    /// Spoken when a figure has no template and the model-written path is off.
    public static let unsupportedSentence = "i can draw a box, a line, an arrow, a circle, a triangle, a star, a smiley or tic tac toe."

    /// Nil for `.freeform`: the model draws that one. The figure is centred in the region `anchor` names,
    /// `size` times its usual size, with a margin that keeps all of it on the screenshot.
    public static func plan(_ figure: SketchFigure, imageWidth: Int, imageHeight: Int,
                            anchor: SketchAnchor = .centre, size: SketchSize = .normal,
                            board: String = emptyBoard) -> SketchPlan? {
        let width = Double(imageWidth), height = Double(imageHeight)
        let shorter = min(width, height)
        // The figures below are written in fractions of m, the shorter side times the size.
        let m = shorter * size.scale
        let reach = (figure == .ticTacToe ? sideFraction / 2 : figureReach) * m
        let pad = edgeMargin * shorter + reach
        func offset(_ index: Int, _ extent: Double) -> Double {
            index == 1 ? extent / 2 : (index == 0 ? pad : extent - pad)
        }
        let cx = offset(anchor.column, width), cy = offset(anchor.row, height)
        let spot = anchor.spokenPlace
        func shape(_ kind: ShapeKind, _ points: [(Double, Double)]) -> InkDrawing {
            .shape(ShapeTag(kind: kind, points: points.map { CGPoint(x: $0.0, y: $0.1) }, label: nil, screenNumber: nil))
        }
        func plan(_ drawings: [InkDrawing], _ sentence: String) -> SketchPlan {
            SketchPlan(drawings: drawings, spokenSentence: sentence)
        }
        switch figure {
        case .freeform:
            return nil
        case .ticTacToe:
            return ticTacToe(board: board, centre: (cx, cy), side: sideFraction * m, place: spot)
        case .box:
            let h = figureFraction * m / 2
            return plan([shape(.polygon, [(cx - h, cy - h), (cx + h, cy - h), (cx + h, cy + h), (cx - h, cy + h)])],
                        "here is a square box \(spot).")
        case .line:
            return plan([shape(.line, [(cx - 0.2 * m, cy), (cx + 0.2 * m, cy)])],
                        "here is a straight line \(anchor == .centre ? "across the middle of your screen" : spot).")
        case .arrow:
            return plan([shape(.arrow, [(cx, cy + 0.17 * m), (cx, cy - 0.17 * m)])],
                        "here is an arrow \(spot), pointing up.")
        case .circle:
            return plan([shape(.circle, [(cx, cy), (cx + 0.175 * m, cy)])],
                        "here is a circle \(spot).")
        case .triangle:
            let h = figureFraction * m / 2
            return plan([shape(.polygon, [(cx, cy - h), (cx + h, cy + h), (cx - h, cy + h)])],
                        "here is a triangle \(spot).")
        case .star:
            let corners = (0..<10).map { index -> (Double, Double) in
                let radius = (index % 2 == 0 ? 0.2 : 0.08) * m
                let angle = (Double(index) * 36 - 90) * .pi / 180
                return (cx + radius * cos(angle), cy + radius * sin(angle))
            }
            return plan([shape(.polygon, corners)], "here is a star \(spot).")
        case .smiley:
            let eyeY = cy - 0.07 * m
            let mouth = [30.0, 60, 90, 120, 150].map { degrees -> (Double, Double) in
                (cx + 0.12 * m * cos(degrees * .pi / 180), cy + 0.12 * m * sin(degrees * .pi / 180))
            }
            return plan([shape(.circle, [(cx, cy), (cx + 0.2 * m, cy)]),
                         shape(.circle, [(cx - 0.075 * m, eyeY), (cx - 0.075 * m + 0.025 * m, eyeY)]),
                         shape(.circle, [(cx + 0.075 * m, eyeY), (cx + 0.075 * m + 0.025 * m, eyeY)]),
                         shape(.curve, mouth)],
                        "here is a smiley face \(spot).")
        case .cross:
            let h = 0.175 * m
            return plan([shape(.line, [(cx - h, cy - h), (cx + h, cy + h)]),
                         shape(.line, [(cx + h, cy - h), (cx - h, cy + h)])],
                        "here is a cross \(spot).")
        case .check:
            return plan([shape(.line, [(cx - 0.15 * m, cy), (cx - 0.05 * m, cy + 0.12 * m)]),
                         shape(.line, [(cx - 0.05 * m, cy + 0.12 * m), (cx + 0.18 * m, cy - 0.14 * m)])],
                        "here is a check mark \(spot).")
        }
    }

    /// The board is 9 characters, row-major: `X`, `O`, anything else is an empty cell (a short
    /// board is padded). The grid is four lines, then the moves in play order: X first, then
    /// alternating, each side's moves in cell order. An empty board says so.
    static func ticTacToe(board: String, centre: (x: Double, y: Double), side: Double, place: String) -> SketchPlan {
        let x0 = centre.x - side / 2, y0 = centre.y - side / 2
        let cell = side / 3
        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> InkDrawing {
            .shape(ShapeTag(kind: .line, points: [CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)], label: nil, screenNumber: nil))
        }
        var drawings = [line(x0 + cell, y0, x0 + cell, y0 + side), line(x0 + 2 * cell, y0, x0 + 2 * cell, y0 + side),
                        line(x0, y0 + cell, x0 + side, y0 + cell), line(x0, y0 + 2 * cell, x0 + side, y0 + 2 * cell)]

        let cells = Array(board.uppercased().prefix(9)) + Array(repeating: Character("."), count: max(0, 9 - board.count))
        let xs = cells.indices.filter { cells[$0] == "X" }, os = cells.indices.filter { cells[$0] == "O" }
        var moves: [(mark: Character, index: Int)] = []
        for turn in 0..<max(xs.count, os.count) {
            if turn < xs.count { moves.append(("X", xs[turn])) }
            if turn < os.count { moves.append(("O", os[turn])) }
        }
        var spoken: [String] = []
        for move in moves {
            let centreX = x0 + (Double(move.index % 3) + 0.5) * cell, centreY = y0 + (Double(move.index / 3) + 0.5) * cell
            let half = 0.3 * cell
            if move.mark == "X" {
                drawings.append(line(centreX - half, centreY - half, centreX + half, centreY + half))
                drawings.append(line(centreX + half, centreY - half, centreX - half, centreY + half))
            } else {
                drawings.append(.shape(ShapeTag(kind: .circle, points: [CGPoint(x: centreX, y: centreY), CGPoint(x: centreX + half, y: centreY)],
                                                label: nil, screenNumber: nil)))
            }
            spoken.append("an \(move.mark == "X" ? "x" : "o") in the \(SketchAnchor(rawValue: move.index)?.name ?? "centre")")
        }
        let sentence: String
        switch spoken.count {
        case 0: sentence = "here is an empty tic tac toe board \(place)."
        case 1: sentence = "here is a tic tac toe board \(place), with \(spoken[0])."
        default: sentence = "here is a tic tac toe board \(place), with \(spoken.dropLast().joined(separator: ", ")) and \(spoken[spoken.count - 1])."
        }
        return SketchPlan(drawings: drawings, spokenSentence: sentence)
    }
}

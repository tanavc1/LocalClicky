//
//  PointSnap.swift
//  LocalBrainKit
//
//  The pure half of snapping the model's point to something real. The grounding model's point is good to a few
//  dozen points at best: a window request came back on the menu bar strip above the window, a control request a
//  little off its control. After the model answers, the app moves the pointer here, with no change to the
//  prompt:
//
//    window request  the model's point is replaced by the title bar centre of the window it means: one whose
//                    title or app name matches the requested object or the model's label; else, for a point in
//                    the menu bar strip, the frontmost window; else the window that holds the point; else the
//                    nearest window within `nearestWindowRadius`. With none of those the point stays (the model
//                    pointing at the Dock icon of an app with no window is right).
//    control request the Accessibility element under the point is kept when its label fuzzy-matches the
//                    model's label; otherwise the best match within `searchRadius` is used; with no match the
//                    point stays where the model put it. Containers and anything larger than
//                    `maximumControlSize` are never a control.
//
//  Every point and frame here is in Core Graphics global points (origin top-left of the primary display, y
//  down): the space of Accessibility frames and window bounds. ScreenMapping converts to and from the
//  screenshot's pixels (imagePoint(forCGGlobalPoint:) and cgGlobalPoint(forDisplayLocalPoint:)). The Accessibility
//  and window-list reads live in the app; this file only decides.
//

import CoreGraphics
import Foundation

/// One Accessibility element near the model's point: the texts that name it and its frame.
public struct SnapCandidate: Equatable, Sendable {
    public var labels: [String]
    public var frame: CGRect
    /// The AX role, for example "AXButton". Nil when unknown.
    public var role: String?

    public init(labels: [String], frame: CGRect, role: String? = nil) {
        self.labels = labels
        self.frame = frame
        self.role = role
    }
}

/// One on-screen window, in the order the window server lists them (front to back).
public struct SnapWindow: Equatable, Sendable {
    public var title: String?
    /// The owning app's name.
    public var owner: String?
    public var frame: CGRect

    public init(title: String? = nil, owner: String? = nil, frame: CGRect) {
        self.title = title
        self.owner = owner
        self.frame = frame
    }
}

public struct PointSnapResult: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case window, ax, none }
    /// The point to use, in Core Graphics global points.
    public let point: CGPoint
    public let kind: Kind
    /// The element label or window title that was matched, for the debug log. Nil for `.none`.
    public let matchedLabel: String?

    public init(point: CGPoint, kind: Kind, matchedLabel: String?) {
        self.point = point
        self.kind = kind
        self.matchedLabel = matchedLabel
    }
}

public enum PointSnap {
    /// How far from the model's point a control may be and still be a match.
    public static let searchRadius: CGFloat = 120
    /// A label matches when its token overlap (Jaccard) reaches this. "send button" matches "send" (0.5) and
    /// "send message" (0.33 does not); "new tab" does not match "new window" (0.33).
    public static let labelThreshold = 0.5
    /// The title bar point sits this far below the window's top edge.
    public static let titleBarInset: CGFloat = 14
    /// A window smaller than this is a badge or a status item, not a window to point at.
    public static let minimumWindowSize = CGSize(width: 120, height: 80)
    /// A model point this close to the top of the display is on the menu bar strip.
    public static let menuBarStrip: CGFloat = 30
    /// A window may be the nearest one to the model's point only within this distance.
    public static let nearestWindowRadius: CGFloat = 60
    /// A control is never larger than this: a bigger element is a container or a pane.
    public static let maximumControlSize = CGSize(width: 400, height: 300)
    /// Roles of elements that hold other elements. Never a control, whatever their label says.
    static let containerRoles: Set<String> = ["AXWindow", "AXSheet", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXWebArea",
                                              "AXToolbar", "AXLayoutArea", "AXApplication"]
    /// The most the Accessibility reads may add to a turn.
    public static let budgetSeconds: Double = 0.15

    // MARK: - Window

    /// The title bar centre of the window the request means, in this order: (a) a window whose title or app name
    /// matches `object` or `label` (`labelScore`), the best score and then the frontmost; (b) for a point in the
    /// menu bar strip, the frontmost window; (c) the topmost window that contains the point; (d) the nearest
    /// window, within `nearestWindowRadius`. Nil when none applies, so the model's point stands. `displayTop` is
    /// the top edge of the display the point is on; the result never sits in the menu bar strip below it.
    public static func windowSnap(modelPoint: CGPoint, object: String? = nil, label: String? = nil,
                                  windows: [SnapWindow], displayTop: CGFloat = 0) -> PointSnapResult? {
        let usable = windows.filter {
            $0.frame.width >= minimumWindowSize.width && $0.frame.height >= minimumWindowSize.height
        }
        guard !usable.isEmpty else { return nil }
        let chosen = titleMatch(object: object, label: label, in: usable)
            ?? (modelPoint.y < displayTop + menuBarStrip ? usable.first : nil)
            ?? usable.first { $0.frame.contains(modelPoint) }
            ?? usable.min { distance(from: modelPoint, to: $0.frame) < distance(from: modelPoint, to: $1.frame) }
                .flatMap { distance(from: modelPoint, to: $0.frame) <= nearestWindowRadius ? $0 : nil }
        guard let chosen else { return nil }
        let inset = min(titleBarInset, chosen.frame.height / 2)
        return PointSnapResult(point: CGPoint(x: chosen.frame.midX, y: max(chosen.frame.minY + inset, displayTop + menuBarStrip)),
                               kind: .window, matchedLabel: chosen.title ?? chosen.owner)
    }

    /// The window whose title or app name best matches the object or the label, at least `labelThreshold`; the
    /// first listed (frontmost) wins a tie. The cue words ("window", "app", "title bar") are not part of a name.
    private static func titleMatch(object: String?, label: String?, in windows: [SnapWindow]) -> SnapWindow? {
        let queries = [object, label].compactMap { $0 }.map(withoutWindowCues).filter { !tokens($0).isEmpty }
        guard !queries.isEmpty else { return nil }
        var best: (window: SnapWindow, score: Double)?
        for window in windows {
            let names = [window.title, window.owner].compactMap { $0 }
            let score = queries.flatMap { query in names.map { labelScore(query, $0) } }.max() ?? 0
            if score >= labelThreshold, score > (best?.score ?? 0) { best = (window, score) }
        }
        return best?.window
    }

    private static func withoutWindowCues(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"\b(?:windows?|apps?|applications?|title ?bars?)\b"#, with: " ",
                                               options: .regularExpression)
    }

    // MARK: - Control

    /// The longest label text kept for one candidate.
    static let maxLabelCharacters = 80

    /// Snap candidates from the Accessibility records near the point. A label is the title or the description,
    /// never the value: a text field's value is what the user typed, so it is never a label, a match or a log
    /// line. Secure fields, records with no frame and records with no label are left out.
    public static func candidates(from records: [AccessibilityElementRecord]) -> [SnapCandidate] {
        records.compactMap { record -> SnapCandidate? in
            guard !record.isSecure, record.role != "AXSecureTextField", !record.frame.isEmpty else { return nil }
            let labels = [record.title, record.description]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { String($0.prefix(maxLabelCharacters)) }
            return labels.isEmpty ? nil : SnapCandidate(labels: labels, frame: record.frame, role: record.role)
        }
    }

    /// The model's point moved onto the element it named. Among candidates whose label matches `label`
    /// (`labelScore` at least `labelThreshold`), leaving out containers (`containerRoles`) and anything larger
    /// than `maximumControlSize`: one that contains the point (the hit) wins, the smallest frame first and the
    /// best score on a tie; otherwise the best score within `radius`, the nearest on a tie. The result is the
    /// centre of that element's frame. No label, no match or an empty frame gives `.none` at the model's own point.
    public static func controlSnap(modelPoint: CGPoint, label: String?, candidates: [SnapCandidate],
                                   radius: CGFloat = searchRadius) -> PointSnapResult {
        let unchanged = PointSnapResult(point: modelPoint, kind: .none, matchedLabel: nil)
        guard let label, !tokens(label).isEmpty else { return unchanged }
        var best: (candidate: SnapCandidate, score: Double, contains: Bool, distance: CGFloat, area: CGFloat, text: String)?
        for candidate in candidates where !candidate.frame.isEmpty && !candidate.frame.isNull {
            guard !containerRoles.contains(candidate.role ?? ""),
                  candidate.frame.width <= maximumControlSize.width, candidate.frame.height <= maximumControlSize.height else { continue }
            guard let (score, text) = candidate.labels.map({ (labelScore(label, $0), $0) }).max(by: { $0.0 < $1.0 }),
                  score >= labelThreshold else { continue }
            let gap = distance(from: modelPoint, to: candidate.frame)
            let contains = candidate.frame.contains(modelPoint)
            guard contains || gap <= radius else { continue }
            let area = candidate.frame.width * candidate.frame.height
            let entry = (candidate, score, contains, gap, area, text)
            if let current = best, !isBetter(entry, than: current) { continue }
            best = entry
        }
        guard let best else { return unchanged }
        return PointSnapResult(point: CGPoint(x: best.candidate.frame.midX, y: best.candidate.frame.midY),
                               kind: .ax, matchedLabel: best.text)
    }

    private static func isBetter(_ a: (candidate: SnapCandidate, score: Double, contains: Bool, distance: CGFloat, area: CGFloat, text: String),
                                 than b: (candidate: SnapCandidate, score: Double, contains: Bool, distance: CGFloat, area: CGFloat, text: String)) -> Bool {
        if a.contains != b.contains { return a.contains }
        if a.contains {
            if a.area != b.area { return a.area < b.area }
            return a.score > b.score
        }
        if a.score != b.score { return a.score > b.score }
        return a.distance < b.distance
    }

    /// The points to ask the Accessibility hit test about: the model's point, then rings of eight at 60 points
    /// and at `radius`. The first is the model's own point.
    public static func probePoints(around point: CGPoint, radius: CGFloat = searchRadius) -> [CGPoint] {
        var points = [point]
        for ring in [radius / 2, radius] {
            for step in 0..<8 {
                let angle = Double(step) * .pi / 4
                points.append(CGPoint(x: point.x + ring * CGFloat(cos(angle)), y: point.y + ring * CGFloat(sin(angle))))
            }
        }
        return points
    }

    // MARK: - Label matching

    /// Token overlap (Jaccard) between two labels, case-insensitive, ignoring filler words. Two tokens are the
    /// same when equal, or when one is a prefix of the other and both have at least four letters ("setting",
    /// "settings"). 0 when either side has no tokens.
    public static func labelScore(_ a: String, _ b: String) -> Double {
        let left = tokens(a), right = tokens(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var matched = 0
        var remaining = right
        for token in left {
            if let index = remaining.firstIndex(where: { sameToken($0, token) }) {
                remaining.remove(at: index)
                matched += 1
            }
        }
        let union = left.count + right.count - matched
        return Double(matched) / Double(union)
    }

    private static let filler: Set<String> = ["the", "a", "an", "of", "to", "for", "and", "in", "on", "at", "is"]

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !filler.contains($0) }
    }

    private static func sameToken(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 4 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

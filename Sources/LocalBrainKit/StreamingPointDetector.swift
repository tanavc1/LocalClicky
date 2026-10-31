//
//  StreamingPointDetector.swift
//  LocalBrainKit
//
//  Finds the pointing tag while the answer is still streaming, so the blue
//  cursor can start flying the moment the tag's closing bracket arrives instead
//  of after the stream ends. It reuses PointingTagParser, so every shape the
//  lenient parser accepts works here too.
//
//  Early detection is a head start, never the authority: the parse of the full
//  text at stream end still decides, and `PointReconciliation` says what to do
//  when the two disagree.
//

import CoreGraphics
import Foundation

/// Feed it the accumulated text after every chunk. It returns the parsed tag
/// once, on the chunk that completes a `[POINT ...]` tag holding a point, and
/// nil on every other call. `[POINT:none]` and a tag cut off before its `]`
/// never fire. Safe to call from the streaming callback's thread.
public final class StreamingPointDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false

    public init() {}

    public func feed(accumulated: String) -> PointingTag? {
        lock.lock(); defer { lock.unlock() }
        guard !hasFired else { return nil }
        // Only a closed [POINT ...] tag counts. The parser's bare "[x,y:label]"
        // fallback is too loose to act on mid-stream.
        guard accumulated.range(of: #"\[POINT\b[^\]]*\]"#,
                                options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let tag = PointingTagParser.parse(from: accumulated)
        guard tag.hasPoint else { return nil }
        hasFired = true
        return tag
    }
}

/// What to do at stream end, given the point that was dispatched early (if any)
/// and the point from the final parse. Both are in screenshot pixel space.
public enum PointReconciliation: Equatable, Sendable {
    /// Neither parse found a point.
    case nothing
    /// The early dispatch matches the final parse; leave the cursor alone.
    case keepEarly
    /// Fly to the final point (no early dispatch, or the final one differs).
    case dispatchFinal(CGPoint)
    /// The final parse has no point but an early one was dispatched. The
    /// flight cannot be recalled; the caller must not act on it (no click).
    case earlyWithdrawn

    public static func reconcile(early: CGPoint?, final: CGPoint?) -> PointReconciliation {
        switch (early, final) {
        case (nil, nil): return .nothing
        case (nil, let final?): return .dispatchFinal(final)
        case (_?, nil): return .earlyWithdrawn
        case (let early?, let final?): return early == final ? .keepEarly : .dispatchFinal(final)
        }
    }
}

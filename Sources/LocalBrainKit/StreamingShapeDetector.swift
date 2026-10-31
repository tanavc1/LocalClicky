//
//  StreamingShapeDetector.swift
//  LocalBrainKit
//
//  The sibling of StreamingPointDetector for ink out. Feed it the accumulated
//  text after every chunk; it returns each newly closed [SHAPE ...] or
//  [HIGHLIGHT ...] tag exactly once, in order, so the overlay can start drawing
//  the moment a tag's closing bracket arrives. A closed tag that does not
//  validate is consumed silently (it never draws and never retries). A tag cut
//  off before its "]" never fires.
//
//  Like early point detection, this is a head start: the full-text parse at
//  stream end (ShapeTagParser.parse) still decides what the final text holds.
//  Assumes the accumulated text only grows by appending. Safe to call from the
//  streaming callback's thread.
//

import Foundation

public final class StreamingShapeDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var consumedTagCount = 0

    public init() {}

    /// Drawings from complete tags not returned by an earlier call. Empty on
    /// most calls; idempotent when the same text is fed again.
    public func feed(accumulated: String) -> [InkDrawing] {
        lock.lock(); defer { lock.unlock() }
        let matches = ShapeTagParser.drawingRegex.matches(in: accumulated, range: NSRange(accumulated.startIndex..., in: accumulated))
        guard matches.count > consumedTagCount else { return [] }
        let fresh = matches[consumedTagCount...]
        consumedTagCount = matches.count
        return fresh.compactMap { match in
            Range(match.range, in: accumulated).flatMap { ShapeTagParser.parseTag(String(accumulated[$0])) }
        }
    }
}

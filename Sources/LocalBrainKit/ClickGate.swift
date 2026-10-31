//
//  ClickGate.swift
//  LocalBrainKit
//
//  Decides WHEN a click turn clicks. The old code clicked a fixed 0.9 s after
//  the target was set, which can be shorter than the cursor's flight (up to
//  1.4 s), so the click could land before the cursor did. The gate fires the
//  click exactly once, only after the click has been requested AND the cursor
//  has arrived at the current target (or a fallback timeout passed, for when no
//  arrival signal can come, for example while the overlay is still playing its
//  welcome animation).
//
//  Each call returns true when the caller should click right now.
//

import Foundation

public struct ClickGate: Equatable, Sendable {
    /// The longest cursor flight is 1.4 s; this adds margin for the stream and
    /// main-thread jitter before the fallback click fires.
    public static let fallbackTimeoutSeconds: Double = 2.0

    private var clickRequested = false
    private var cursorArrived = false
    private var timedOut = false
    private var hasFired = false

    public init() {}

    /// A click is wanted at the current target. True if it can fire now.
    public mutating func requestClick() -> Bool { evaluate { $0.clickRequested = true } }

    /// The cursor landed on the current target.
    public mutating func noteArrival() -> Bool { evaluate { $0.cursorArrived = true } }

    /// The fallback timeout elapsed with no arrival.
    public mutating func noteTimeout() -> Bool { evaluate { $0.timedOut = true } }

    /// The cursor was sent to a different target: an earlier arrival no longer
    /// counts. A request or fire that already happened is kept.
    public mutating func targetChanged() {
        cursorArrived = false
    }

    /// Start of a new turn: forget everything.
    public mutating func reset() { self = ClickGate() }

    private mutating func evaluate(_ update: (inout ClickGate) -> Void) -> Bool {
        update(&self)
        guard clickRequested, !hasFired, cursorArrived || timedOut else { return false }
        hasFired = true
        return true
    }
}

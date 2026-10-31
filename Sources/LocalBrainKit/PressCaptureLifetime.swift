//
//  PressCaptureLifetime.swift
//  LocalBrainKit
//
//  When the key-press capture (and the ink prepared from it) may be dropped.
//  The voice state is three separate publishes, so a single emission can be a
//  half-written snapshot: at key up the recording flag falls before the
//  finalizing flag rises, and an observer sees "all idle" for one emission
//  while the transcript is still on its way. Treating that snapshot as the end
//  of the session discards the capture before the turn can claim it.
//

import Foundation

@MainActor
public final class PressCaptureLifetime {
    private let isSettledIdle: () -> Bool
    private let discard: () -> Void
    private var pressCount = 0

    public init(isSettledIdle: @escaping () -> Bool, discard: @escaping () -> Void) {
        self.isSettledIdle = isSettledIdle
        self.discard = discard
    }

    /// Call when a new press starts its capture, so an idle emission left over
    /// from the previous session cannot discard the new one.
    public func beginPress() {
        pressCount += 1
    }

    /// Call for every voice-activity emission. An idle emission only counts if
    /// the live state is still idle after the main-queue turn, by which time
    /// every write of a multi-flag transition has landed.
    public func voiceActivityEmitted(isIdle: Bool) {
        guard isIdle else { return }
        let pressAtEmission = pressCount
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pressCount == pressAtEmission, self.isSettledIdle() else { return }
            self.discard()
        }
    }
}

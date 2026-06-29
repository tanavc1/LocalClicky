//
//  TimerService.swift
//  LocalClicky
//
//  A reliable in-app countdown timer. macOS Clock.app exposes no public way to
//  set a timer programmatically (no URL scheme, no scripting dictionary), so
//  rather than fragile UI-scripting that would break, LocalClicky runs the timer
//  itself and announces it out loud (plus a sound) when it finishes. This is
//  fully local and never gets wedged.
//

import AppKit
import Foundation

@MainActor
final class TimerService {
    private var activeTimers: [UUID: DispatchWorkItem] = [:]

    /// Called on the main actor when a timer finishes, with its spoken duration
    /// (e.g. "4 minutes") so the companion can announce it.
    var onTimerFinished: ((String) -> Void)?

    /// Number of timers currently counting down.
    var activeTimerCount: Int { activeTimers.count }

    /// Starts a countdown. When it elapses it plays an alert sound and invokes
    /// `onTimerFinished`. Multiple timers can run at once.
    func startTimer(seconds: Int, spokenDuration: String) {
        let id = UUID()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activeTimers[id] = nil
            self.playAlertSound()
            self.onTimerFinished?(spokenDuration)
        }
        activeTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds), execute: work)
    }

    private func playAlertSound() {
        // A pleasant, attention-getting system sound; falls back to a beep.
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

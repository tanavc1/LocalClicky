//
//  PressCapturePolicy.swift
//  LocalBrainKit
//
//  Rules for the screenshot that is taken when the push-to-talk key goes down
//  (in parallel with listening) and reused when the transcript arrives. The
//  capture only ever starts when a screen turn could actually happen, and it is
//  not reused once it is too old to describe what the user is looking at.
//

import Foundation

public enum PressCapturePolicy {
    /// A key held longer than this means the screen may have changed while the
    /// user talked, so the turn takes a fresh capture instead.
    public static let maxReuseAgeSeconds: Double = 15

    /// The same two conditions the router needs before it will choose a screen
    /// route: vision mode is on and screen recording is granted. Without both,
    /// no capture is started at key press.
    public static func shouldCapture(textOnlyMode: Bool, screenPermissionGranted: Bool) -> Bool {
        !textOnlyMode && screenPermissionGranted
    }

    public static func shouldReuse(ageSeconds: Double) -> Bool {
        ageSeconds >= 0 && ageSeconds <= maxReuseAgeSeconds
    }
}

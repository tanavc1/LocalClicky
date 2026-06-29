//
//  SpotifyController.swift
//  LocalClicky
//
//  Controls the Spotify desktop app. Playback transport (play/pause/next/
//  previous) goes through Spotify's scripting bridge; "play <song>" opens a
//  Spotify search for it (reliable — there's no keyless way to resolve a spoken
//  song to an exact track URI, and playing the wrong track would be worse than
//  showing the right search).
//
//  Sending Apple events to another app is gated by macOS Automation permission.
//  The first control prompts the user (this is why Info.plist must carry
//  NSAppleEventsUsageDescription — without it macOS hard-crashes the process).
//  Every call is wrapped so a denial or a missing/closed Spotify fails gracefully
//  instead of crashing.
//

import AppKit
import Foundation
import LocalBrainKit

@MainActor
enum SpotifyController {

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
            || FileManager.default.fileExists(atPath: "/Applications/Spotify.app")
    }

    enum Outcome {
        case ok
        case notInstalled
        case permissionDenied
        case failed
    }

    /// Performs the requested Spotify action. Returns an outcome the caller turns
    /// into a spoken response.
    @discardableResult
    static func perform(_ action: ComputerActionPlanner.SpotifyAction) -> Outcome {
        guard isInstalled else { return .notInstalled }

        switch action {
        case .play:
            return runScript("tell application \"Spotify\" to play")
        case .pause:
            return runScript("tell application \"Spotify\" to pause")
        case .next:
            return runScript("tell application \"Spotify\" to next track")
        case .previous:
            return runScript("tell application \"Spotify\" to previous track")
        case .playQuery(let query):
            // Open Spotify's search for the song so the user lands right on it.
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
            if let url = URL(string: "spotify:search:\(encoded)") {
                NSWorkspace.shared.open(url)
                return .ok
            }
            return .failed
        }
    }

    /// Runs a one-line AppleScript against Spotify, mapping the common Automation
    /// errors to a clean outcome. Never throws an uncatchable exception.
    private static func runScript(_ source: String) -> Outcome {
        guard let script = NSAppleScript(source: source) else { return .failed }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .ok }

        let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        print("⚠️ Spotify control error \(code): \(errorInfo[NSAppleScript.errorMessage] ?? "")")
        // -1743: user hasn't granted Automation permission. -600/-609: not running.
        if code == -1743 { return .permissionDenied }
        return .failed
    }
}

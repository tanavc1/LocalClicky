//
//  GatewayErrorSpeech.swift
//  LocalBrainKit
//
//  Turns an error body from the Studio gateway into the one short sentence the
//  companion says out loud, so "the studio is busy" is heard instead of a
//  generic "my local brain hiccuped".
//
//  Contract with the gateway: an error body is JSON with an `error` string for
//  logs and, newer gateways, a `speakable` string written for text-to-speech.
//  Order: `speakable` if present, else a known `error` text mapped here, else
//  nil (the caller keeps its old line).
//

import Foundation

public enum GatewayErrorSpeech {

    /// The line to speak for an HTTP error body, or nil when the body is not a
    /// recognised gateway error. Plain Ollama errors (for example a missing
    /// model) return nil on purpose and keep their existing handling.
    public static func speakable(fromBody body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let speakable = object["speakable"] as? String {
            let trimmed = speakable.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        guard let errorText = (object["error"] as? String)?.lowercased() else { return nil }
        for (needle, line) in knownErrors where errorText.contains(needle) {
            return line
        }
        return nil
    }

    /// Error texts the gateway has always sent (before it added `speakable`),
    /// matched case-insensitively as substrings. Checked in order.
    private static let knownErrors: [(needle: String, line: String)] = [
        ("studio connection is off", "the studio connection is off so that model is not available"),
        ("studio did not answer", "the studio is not answering right now"),
        ("is not loaded on the studio", "that model is not loaded on the studio"),
        ("studio is busy", "the studio is busy with another job so try again in a moment"),
        ("needs anthropic_api_key", "claude needs an api key to see the screen"),
        ("is not reachable", "the local ollama engine is not running"),
    ]
}

//
//  SpokenTextSegmenter.swift
//  LocalBrainKit
//
//  Pure string helpers for speaking a model response sentence-by-sentence *as it
//  streams*, instead of waiting for the whole answer. This is the main perceived-
//  latency win: the companion starts talking after the first sentence is ready
//  while the rest is still being generated.
//
//  Two things make it safe:
//   1. We never speak past the start of a pointing tag (`[POINT:…]`), so the tag
//      is never read aloud.
//   2. During streaming we only treat a sentence as "complete" when its
//      terminator is followed by whitespace. That avoids splitting decimals like
//      "3.5" and avoids speaking a half-finished sentence at the streaming edge;
//      the final sentence is handled by `remainder` once the stream ends.
//

import Foundation

public enum SpokenTextSegmenter {

    /// The portion of a (possibly partial) response that is safe to speak:
    /// everything before a pointing tag begins. The spoken-answer prompt forbids
    /// markdown/code, so a "[" only ever introduces a tag.
    public static func speakablePrefix(_ text: String) -> String {
        if let bracket = text.firstIndex(of: "[") {
            return String(text[..<bracket])
        }
        return text
    }

    /// Given the speakable text so far and how many characters were already
    /// spoken, returns the next run of COMPLETE sentences plus the new
    /// spoken-length, or nil if nothing new is fully complete yet.
    public static func nextCompleteSentences(speakable: String,
                                             alreadySpoken: Int) -> (text: String, newSpokenLength: Int)? {
        let characters = Array(speakable)
        guard characters.count > alreadySpoken else { return nil }
        let pending = Array(characters[alreadySpoken...])

        var lastBoundary: Int? = nil
        for index in pending.indices {
            let character = pending[index]
            if character == "\n" {
                lastBoundary = index + 1
            } else if character == "." || character == "!" || character == "?" {
                // Only a real boundary if a space follows — so "3.5" stays intact
                // and a terminator at the very edge waits for the next token.
                let nextIndex = index + 1
                if nextIndex < pending.count, pending[nextIndex].isWhitespace {
                    lastBoundary = nextIndex
                }
            }
        }

        guard let boundary = lastBoundary else { return nil }
        let ready = String(pending[0..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ready.isEmpty else { return nil }
        return (ready, alreadySpoken + boundary)
    }

    /// Any remaining unspoken speakable text, to flush once the stream is done
    /// (this is where the final sentence — which has no trailing space — gets
    /// spoken).
    public static func remainder(speakable: String, alreadySpoken: Int) -> String {
        let characters = Array(speakable)
        guard characters.count > alreadySpoken else { return "" }
        return String(characters[alreadySpoken...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

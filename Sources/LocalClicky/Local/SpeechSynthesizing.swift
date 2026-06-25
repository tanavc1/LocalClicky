//
//  SpeechSynthesizing.swift
//  LocalClicky
//
//  A tiny abstraction over "say this out loud" so the app can prefer the
//  natural-sounding neural voice (Piper, run in-process via the sherpa-onnx
//  runtime) and transparently fall back to Apple's AVSpeechSynthesizer if the
//  bundled voice is missing or fails. Everything stays on-device either way.
//

import Foundation
import LocalBrainKit

/// Tracks how much of a streaming response has already been spoken, so each
/// `onText` update can emit only the newly-completed sentences. `onText` is
/// called serially by the streaming client, but the lock keeps it safe even so.
final class StreamingSpeechProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var spokenLength = 0

    /// Newly-complete sentence(s) from the speakable text, or nil if none yet.
    func advance(speakable: String) -> (text: String, newSpokenLength: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let result = SpokenTextSegmenter.nextCompleteSentences(
            speakable: speakable, alreadySpoken: spokenLength) else { return nil }
        spokenLength = result.newSpokenLength
        return result
    }

    /// Whatever is left unspoken, called once after streaming completes.
    func remainder(speakable: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let text = SpokenTextSegmenter.remainder(speakable: speakable, alreadySpoken: spokenLength)
        spokenLength = Array(speakable).count
        return text
    }
}

/// Anything that can speak text aloud, with a pollable `isPlaying` flag (the
/// transient-cursor hide loop relies on it flipping back to false when speech
/// ends).
@MainActor
protocol SpeechSynthesizing: AnyObject {
    var isPlaying: Bool { get }
    /// Speaks `text`. May be called repeatedly to queue successive sentences;
    /// clips play back in order. Returns once the clip is synthesized and queued.
    func speakText(_ text: String) async throws
    func stopPlayback()
}

/// Prefers the neural Piper voice; falls back to Apple's synthesizer. The
/// fallback is automatic and per-utterance, so a transient failure in the neural
/// path never leaves the companion silent.
@MainActor
final class SpeechSynthesisCoordinator: SpeechSynthesizing {
    private let neural: PiperSpeechSynthesisClient?
    private let fallback: AppleSpeechSynthesisClient

    /// True if the high-quality neural voice is the one in use.
    var isUsingNeuralVoice: Bool { neural != nil }

    init() {
        neural = PiperSpeechSynthesisClient.make()
        fallback = AppleSpeechSynthesisClient()
        if neural == nil {
            print("⚠️ Piper neural voice unavailable — using Apple voice fallback.")
        } else {
            print("🔊 Using Piper neural voice (en_US-ryan, via sherpa-onnx).")
        }
    }

    var isPlaying: Bool { (neural?.isPlaying ?? false) || fallback.isPlaying }

    func speakText(_ text: String) async throws {
        if let neural {
            do {
                try await neural.speakText(text)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Neural synthesis hiccuped — don't go silent, use Apple voice.
                print("⚠️ Neural TTS failed (\(error)); falling back to Apple voice.")
            }
        }
        try await fallback.speakText(text)
    }

    func stopPlayback() {
        neural?.stopPlayback()
        fallback.stopPlayback()
    }

    /// Pays the one-time graph warm-up so the first real answer speaks instantly.
    func warmUp() {
        neural?.warmUp()
    }
}

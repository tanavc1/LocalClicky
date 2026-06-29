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
    private var neural: PiperSpeechSynthesisClient?
    private let fallback: AppleSpeechSynthesisClient
    private var hasDisabledNeuralVoice = false
    private var consecutiveNeuralFailures = 0
    /// Only give up on the neural voice for the rest of the session after this
    /// many *consecutive* failures. A single slow or stalled synthesis — e.g. the
    /// one-time graph warm-up cost on the very first utterance, or a momentary CPU
    /// spike — must not be enough to lose the good-sounding voice for good.
    private let neuralFailureToleranceBeforeFallback = 3

    /// True if the high-quality neural voice is the one in use.
    var isUsingNeuralVoice: Bool { neural != nil && !hasDisabledNeuralVoice }

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
        if let neural, !hasDisabledNeuralVoice {
            do {
                try await speakWithNeuralTimeout(neural, text: text)
                consecutiveNeuralFailures = 0
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Neural synthesis hiccuped or stalled — speak this one line with
                // the Apple voice so the companion never goes silent, but keep the
                // neural voice for the next line. Only after several consecutive
                // failures (a genuinely broken neural path) do we switch away for
                // the rest of the session.
                consecutiveNeuralFailures += 1
                neural.stopPlayback()
                if consecutiveNeuralFailures >= neuralFailureToleranceBeforeFallback {
                    print("⚠️ Neural TTS failed \(consecutiveNeuralFailures)× in a row (\(error)); using the Apple voice for the rest of this session.")
                    self.neural = nil
                    hasDisabledNeuralVoice = true
                } else {
                    print("⚠️ Neural TTS hiccup #\(consecutiveNeuralFailures) (\(error)); speaking this line with the Apple voice.")
                }
            }
        }
        try await fallback.speakText(text)
    }

    private func speakWithNeuralTimeout(_ neural: PiperSpeechSynthesisClient, text: String) async throws {
        // The timeout budget scales with how much text we're synthesizing and is
        // generous enough to absorb the one-time graph warm-up on the first
        // utterance. Real synthesis runs ~20× faster than real time on Apple
        // silicon, so this only ever trips on a genuine stall — not on normal
        // (even cold) use, which is what used to wrongly drop us to the Apple voice.
        let timeoutSeconds = min(20.0, 6.0 + Double(text.count) * 0.05)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await neural.speakText(text)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw SpeechSynthesisError.neuralTimedOut
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func stopPlayback() {
        neural?.stopPlayback()
        fallback.stopPlayback()
    }

    /// Pays the one-time graph warm-up so the first real answer speaks instantly.
    func warmUp() {
        neural?.warmUp()
    }

    enum SpeechSynthesisError: Error {
        case neuralTimedOut
    }
}

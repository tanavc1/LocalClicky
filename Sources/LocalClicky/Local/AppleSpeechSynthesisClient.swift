//
//  AppleSpeechSynthesisClient.swift
//  LocalClicky
//
//  On-device text-to-speech, backed by AVSpeechSynthesizer. This is the local
//  replacement for the cloud TTS in the original Clicky — the spoken answer is
//  synthesized entirely on the Mac, so the whole push-to-talk → answer → voice
//  loop works with the network off and nothing you hear was generated remotely.
//

import AVFoundation
import Foundation

@MainActor
final class AppleSpeechSynthesisClient: NSObject, SpeechSynthesizing {
    /// Must stay strongly referenced for the whole utterance — if the
    /// synthesizer deallocates, speech stops and didFinish never fires.
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// True from speech start until the utterance finishes or is stopped. The
    /// transient-cursor hide loop polls this, so it must reliably flip back to
    /// false when playback ends.
    private(set) var isPlaying = false

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Speaks `text` with the best installed US-English voice. Returns as soon as
    /// speech is queued (the "returns when playback starts" contract the rest of
    /// the app relies on for state transitions).
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()

        // Nothing to say — return without arming isPlaying, or the empty
        // utterance never fires didFinish and the transient-hide loop hangs.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.bestAvailableEnglishVoice()

        isPlaying = true
        speechSynthesizer.speak(utterance)
    }

    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
    }

    /// Highest-quality installed en-US voice. Premium/enhanced voices only exist
    /// if the user downloaded them in System Settings → Spoken Content; the
    /// compact default is the floor, not the goal.
    private static func bestAvailableEnglishVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" }
        let premiumVoice = englishVoices.first { $0.quality == .premium }
        let enhancedVoice = englishVoices.first { $0.quality == .enhanced }
        return premiumVoice ?? enhancedVoice ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension AppleSpeechSynthesisClient: AVSpeechSynthesizerDelegate {
    // Delegate callbacks arrive on an arbitrary queue — hop to the main actor
    // before touching isPlaying.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isPlaying = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isPlaying = false }
    }
}

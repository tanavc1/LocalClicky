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

    /// Called when an utterance queued with an id starts speaking (see SpeechSynthesizing).
    var onClipStart: (@MainActor (SpeechClipStart) -> Void)?
    /// Clip ids of utterances that have not started yet, keyed by the utterance.
    private var pendingClipIDs: [ObjectIdentifier: Int] = [:]

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Speaks `text` with the best installed US-English voice. Returns as soon as
    /// speech is queued (the "returns when playback starts" contract the rest of
    /// the app relies on for state transitions).
    func speakText(_ text: String, clipID: Int?) async throws {
        try Task.checkCancellation()

        // Nothing to say — return without arming isPlaying, or the empty
        // utterance never fires didFinish and the transient-hide loop hangs.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.bestAvailableEnglishVoice()

        if let clipID { pendingClipIDs[ObjectIdentifier(utterance)] = clipID }
        isPlaying = true
        speechSynthesizer.speak(utterance)
    }

    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        pendingClipIDs.removeAll()
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
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            // Spoken text starts right away, so there is no silence to report.
            guard let id = self.pendingClipIDs.removeValue(forKey: key) else { return }
            self.onClipStart?(SpeechClipStart(id: id, audibleIn: 0))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.pendingClipIDs.removeValue(forKey: key); self.isPlaying = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.pendingClipIDs.removeValue(forKey: key); self.isPlaying = false }
    }
}

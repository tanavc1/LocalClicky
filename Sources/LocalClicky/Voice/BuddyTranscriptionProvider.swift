//
//  BuddyTranscriptionProvider.swift
//  LocalClicky
//
//  Shared protocol surface for voice transcription backends. LocalClicky ships
//  exactly one: Apple's on-device Speech framework, so push-to-talk transcription
//  runs entirely on the Mac with no network and no cloud transcription service.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    /// LocalClicky only ever uses Apple's on-device speech recognition. There is
    /// no cloud transcription backend to fall back to (or leak audio to) — the
    /// whole point is that nothing you say leaves the machine.
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = AppleSpeechTranscriptionProvider()
        print("🎙️ Transcription: using \(provider.displayName) (on-device)")
        return provider
    }
}

//
//  PiperSpeechSynthesisClient.swift
//  LocalClicky
//
//  On-device neural text-to-speech. Plays a Piper voice (en_US-ryan-medium) via
//  the sherpa-onnx runtime, linked in-process through its C API so the model is
//  loaded once and every subsequent utterance synthesizes in well under a tenth
//  of a second (≈20× real-time on an M2). This is the natural-sounding
//  replacement for the robotic compact AVSpeechSynthesizer voices.
//
//  Why in-process instead of shelling out to a CLI: invoking a TTS binary per
//  utterance reloads the ~60 MB model every time (~2-3 s). Holding the model
//  resident makes synthesis effectively instant.
//

import AVFoundation
import CSherpaOnnx
import Foundation

@MainActor
final class PiperSpeechSynthesisClient: NSObject, SpeechSynthesizing, AVAudioPlayerDelegate {

    /// Opaque `const SherpaOnnxOfflineTts *`. Wrapped so it can cross to the
    /// synthesis background task; the handle is created once and only read.
    private struct TTSHandle: @unchecked Sendable { let pointer: OpaquePointer }
    private let handle: TTSHandle
    private let sampleRate: Int

    /// All synthesis goes through this one actor so calls into the shared TTS
    /// handle are strictly serialized — see `SynthesisEngine` for why that
    /// matters.
    private let engine: SynthesisEngine

    /// WAV clips waiting to play, so successive sentences (streamed from the
    /// model) speak back-to-back without overlapping.
    private var clipQueue: [Data] = []
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false

    /// Returns nil if the bundled voice can't be found or the model won't load,
    /// so the coordinator can fall back to the Apple voice. (A factory rather
    /// than a failable `init()` to avoid colliding with `NSObject.init()`.)
    static func make() -> PiperSpeechSynthesisClient? {
        guard let voiceDirectory = locateVoiceDirectory() else { return nil }
        return PiperSpeechSynthesisClient(voiceDirectory: voiceDirectory)
    }

    private init?(voiceDirectory: URL) {
        let modelPath = voiceDirectory.appendingPathComponent("en_US-ryan-medium.onnx").path
        let tokensPath = voiceDirectory.appendingPathComponent("tokens.txt").path
        let dataDirPath = voiceDirectory.appendingPathComponent("espeak-ng-data").path

        // strdup so the C strings outlive the call; sherpa copies them internally,
        // so we free right after creating the engine.
        let cModel = strdup(modelPath)
        let cTokens = strdup(tokensPath)
        let cData = strdup(dataDirPath)
        let cProvider = strdup("cpu")
        defer { free(cModel); free(cTokens); free(cData); free(cProvider) }

        var config = SherpaOnnxOfflineTtsConfig()
        config.model.vits.model = UnsafePointer(cModel)
        config.model.vits.tokens = UnsafePointer(cTokens)
        config.model.vits.data_dir = UnsafePointer(cData)
        config.model.vits.noise_scale = 0.667
        config.model.vits.noise_scale_w = 0.8
        config.model.vits.length_scale = 1.0
        // Four threads keeps real-time factor near 0.05 on M-series performance
        // cores while leaving the rest of the machine responsive.
        config.model.num_threads = 4
        config.model.provider = UnsafePointer(cProvider)
        config.max_num_sentences = 1

        guard let ttsPointer = withUnsafePointer(to: &config, { SherpaOnnxCreateOfflineTts($0) }) else {
            return nil
        }
        let ttsHandle = TTSHandle(pointer: ttsPointer)
        self.handle = ttsHandle
        self.sampleRate = Int(SherpaOnnxOfflineTtsSampleRate(ttsPointer))
        self.engine = SynthesisEngine(handle: ttsHandle)
        super.init()
    }

    deinit {
        SherpaOnnxDestroyOfflineTts(handle.pointer)
    }

    // MARK: - SpeechSynthesizing

    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let wav = await engine.synthesize(trimmed) else {
            throw PiperError.synthesisFailed
        }
        try Task.checkCancellation()
        enqueue(wav)
    }

    func stopPlayback() {
        clipQueue.removeAll()
        player?.stop()
        player = nil
        isPlaying = false
    }

    /// One throwaway synthesis to pay the graph's first-run cost up front, so the
    /// user's first real answer speaks without a stutter. It runs through the same
    /// serial engine as everything else, so even if the user triggers a real
    /// request before warm-up finishes, the two syntheses queue instead of racing.
    func warmUp() {
        let engine = self.engine
        Task.detached(priority: .utility) {
            _ = await engine.synthesize("ready.")
        }
    }

    // MARK: - Synthesis (serialized, off the main actor)

    /// Owns every call into the sherpa-onnx TTS handle and runs them one at a
    /// time. The underlying VITS/ONNX session is **not** safe for concurrent
    /// `Generate` calls: two overlapping syntheses on a single handle corrupt
    /// each other's inference state and the audio comes out as garbled, nonsense
    /// speech. Because this is an `actor` and `synthesize` has no internal
    /// suspension point, calls are strictly serialized — warm-up, streamed
    /// sentences, and error/onboarding lines can never overlap on the handle, so
    /// the gibberish-audio failure mode is structurally impossible. Synthesis is
    /// CPU-bound but runs on the actor's background executor, never the main
    /// thread.
    private actor SynthesisEngine {
        private let handle: TTSHandle
        init(handle: TTSHandle) { self.handle = handle }

        /// Synthesizes `text` to an in-memory WAV, or nil if generation fails.
        func synthesize(_ text: String) -> Data? {
            guard let audio = text.withCString({
                SherpaOnnxOfflineTtsGenerate(handle.pointer, $0, 0, 1.0)
            }) else { return nil }
            defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
            let generated = audio.pointee
            guard let samples = generated.samples, generated.n > 0 else { return nil }
            return PiperSpeechSynthesisClient.makeWAVData(
                samples: samples, count: Int(generated.n),
                sampleRate: Int(generated.sample_rate))
        }
    }

    /// Wraps mono float32 samples in [-1, 1] as a 16-bit PCM WAV so AVAudioPlayer
    /// can play them straight from memory (no temp file).
    private nonisolated static func makeWAVData(samples: UnsafePointer<Float>, count: Int, sampleRate: Int) -> Data {
        let channels = 1, bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = count * blockAlign

        var data = Data(capacity: 44 + dataSize)
        func putString(_ s: String) { data.append(contentsOf: s.utf8) }
        func putU32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func putU16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        putString("RIFF"); putU32(UInt32(36 + dataSize)); putString("WAVE")
        putString("fmt "); putU32(16); putU16(1); putU16(UInt16(channels))
        putU32(UInt32(sampleRate)); putU32(UInt32(byteRate))
        putU16(UInt16(blockAlign)); putU16(UInt16(bitsPerSample))
        putString("data"); putU32(UInt32(dataSize))

        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0)
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    // MARK: - Playback queue

    private func enqueue(_ wav: Data) {
        clipQueue.append(wav)
        isPlaying = true
        playNextIfIdle()
    }

    private func playNextIfIdle() {
        guard player?.isPlaying != true else { return }
        guard !clipQueue.isEmpty else { isPlaying = false; return }
        let wav = clipQueue.removeFirst()
        do {
            let newPlayer = try AVAudioPlayer(data: wav)
            newPlayer.delegate = self
            player = newPlayer
            isPlaying = true
            // If playback can't actually start, the finish-delegate never fires,
            // so isPlaying would stay true forever — wedging the transient-hide
            // loop and anything that waits on isPlaying. Drop the clip and move on.
            if !newPlayer.play() {
                player = nil
                playNextIfIdle()
            }
        } catch {
            // Skip the bad clip and keep going rather than getting stuck.
            playNextIfIdle()
        }
    }

    // Delegate callbacks arrive off the main actor — hop back before touching state.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.playNextIfIdle()
        }
    }

    // MARK: - Locating the bundled voice

    private static func locateVoiceDirectory() -> URL? {
        let voiceFile = "en_US-ryan-medium.onnx"

        // 1) Inside LocalClicky.app: Contents/Resources/sherpa/voice
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("sherpa/voice", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent(voiceFile).path) {
                return bundled
            }
        }

        // 2) Development (`swift run`): walk up from the executable to the repo
        //    root and look in vendor/sherpa/voice.
        var directory = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<5 {
            guard let current = directory else { break }
            let candidate = current.appendingPathComponent("vendor/sherpa/voice", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(voiceFile).path) {
                return candidate
            }
            directory = current.deletingLastPathComponent()
        }
        return nil
    }

    enum PiperError: Error { case synthesisFailed }
}

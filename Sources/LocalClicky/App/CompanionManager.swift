//
//  CompanionManager.swift
//  LocalClicky
//
//  Central state manager for the companion voice mode — the fully-local
//  rebuild. Owns the push-to-talk pipeline (dictation manager + global shortcut
//  monitor + overlay) and runs the answer pipeline entirely on-device:
//
//    push-to-talk → Apple on-device speech-to-text → screenshot → local vision
//    model (Ollama qwen2.5-vl) → spoken answer (AVSpeechSynthesizer) + a
//    [POINT:x,y] tag that flies the blue cursor to the right UI element.
//
//  Nothing in this file ever calls a network service outside of the local
//  Ollama server on 127.0.0.1.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import LocalBrainKit
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the buddy
    /// should fly to and point at. Parsed from the local model's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// Provider + first-token latency for the most recent response, shown as a
    /// small badge near the cursor ("local · 0.6s · 41 tok/s"). Cleared when the
    /// next push-to-talk begins.
    @Published private(set) var lastResponseLatencyDescription: String?

    /// Whether the local Ollama server is reachable. Drives the panel nudge to
    /// start Ollama if it isn't running.
    @Published private(set) var isLocalEngineReachable = true
    /// Required models that aren't installed yet (so the panel can show the
    /// exact `ollama pull` to run).
    @Published private(set) var missingLocalModels: [String] = []

    // MARK: - Onboarding state (kept for the overlay's first-run experience)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0

    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    // MARK: - Local inference

    /// The single client for the local Ollama server. All chat and vision
    /// requests go here — there is no cloud client anywhere in this app.
    private let ollamaClient = OllamaClient()

    /// On-device voice. Prefers the natural-sounding neural Piper voice and
    /// falls back to Apple's synthesizer if it's unavailable. Replaces the cloud
    /// TTS; works with the network off.
    private let speechSynthesizer = SpeechSynthesisCoordinator()

    /// Model-picker identities. "Vision" sends a screenshot to the local VLM so
    /// Clicky can see the screen and point; "Text" uses the faster text-only
    /// model when the screen isn't relevant.
    static let visionModeID = "local-vision"
    static let textModeID = "local-text"

    /// Conversation history so the model remembers prior exchanges this session.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// Whether the immediately-preceding answered turn actually used the screen.
    /// The router reads this so a pronoun like "that" in "add two to that" is
    /// understood as the last answer (after a text turn) rather than something
    /// on screen.
    private var previousTurnUsedScreen = false

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var currentResponseIdentifier: UUID?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user speaks
    /// again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all required permissions are granted.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    @Published private(set) var isOverlayVisible: Bool = false

    /// The selected response mode (vision or text). Persisted to UserDefaults.
    @Published var selectedModel: String = CompanionManager.validatedStoredModeSelection()

    private static let knownModeIDs = [visionModeID, textModeID]

    private static func validatedStoredModeSelection() -> String {
        guard let stored = UserDefaults.standard.string(forKey: "localClickyMode"),
              knownModeIDs.contains(stored) else {
            return visionModeID
        }
        return stored
    }

    /// True when the picker is on the text-only (no screen) model.
    var isTextOnlyMode: Bool { selectedModel == Self.textModeID }

    func setSelectedModel(_ mode: String) {
        selectedModel = mode
        UserDefaults.standard.set(mode, forKey: "localClickyMode")
    }

    /// User preference for whether the Clicky cursor should be shown. When off,
    /// the overlay is hidden and push-to-talk briefly fades it in for each
    /// interaction. Persisted across launches.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 LocalClicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        refreshLocalEngineStatus()

        // Pay one-time warm-up costs now, in the background, so the user's first
        // interaction is snappy: the neural voice's inference graph, and both
        // Ollama models loaded and resident (keep_alive keeps them warm).
        speechSynthesizer.warmUp()
        warmUpLocalModels()

        // If onboarding is done and permissions are granted, show the cursor now.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Sends a tiny throwaway request to each local model so Ollama loads them
    /// into memory before the first real question. With keep_alive they stay
    /// resident, turning a cold multi-second first answer into a warm one.
    private func warmUpLocalModels() {
        Task.detached(priority: .utility) { [ollamaClient] in
            for model in LocalModels.requiredModels {
                let contextWindow = model == LocalModels.chatModel ? 4096 : 8192
                _ = try? await ollamaClient.streamChat(
                    model: model,
                    messages: [.user("hi")],
                    temperature: 0.0,
                    maxTokens: 1,
                    contextWindow: contextWindow,
                    onText: { _ in }
                )
            }
        }
    }

    /// Checks that the local Ollama server is up and the required models are
    /// installed, so the panel can guide the user if not.
    func refreshLocalEngineStatus() {
        Task {
            let reachable = await ollamaClient.isServerReachable()
            var missing: [String] = []
            if reachable {
                missing = (try? await ollamaClient.missingRequiredModels()) ?? []
            }
            await MainActor.run {
                self.isLocalEngineReachable = reachable
                self.missingLocalModels = missing
            }
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing animation.
    /// Triggers the onboarding sequence.
    func triggerOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        hasCompletedOnboarding = true
        startOnboardingMusic()
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the panel footer link.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        startOnboardingMusic()
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ LocalClicky: failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }
        let fadeSteps = 30
        let stepInterval = 3.0 / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps
        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement
            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        stopOnboardingMusic()
    }

    func refreshAllPermissions() {
        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Screen content permission is persisted — once approved via the
        // SCShareableContent picker, we don't re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        // "Screen Content" is really the same macOS permission as Screen
        // Recording (ScreenCaptureKit just needs that grant). Requiring a
        // separate manual click left users stuck with every System Settings
        // toggle on but the app still saying "permissions needed." So once
        // Screen Recording is granted, confirm screen content automatically.
        if hasScreenRecordingPermission && !hasScreenContentPermission {
            autoConfirmScreenContentIfPossible()
        } else if !hasScreenRecordingPermission && hasScreenContentPermission {
            // Screen Recording was revoked (or wiped by `tccutil reset` / a fresh
            // reinstall). Since screen content rides on the same underlying TCC
            // grant, a persisted "granted" flag is now stale — clear it so the UI
            // doesn't show "Granted" for a permission the running app no longer has.
            hasScreenContentPermission = false
            UserDefaults.standard.set(false, forKey: "hasScreenContentPermission")
        }
    }

    private var isAutoConfirmingScreenContent = false

    /// Silently verifies ScreenCaptureKit access (no picker, no capture stored)
    /// when Screen Recording is already granted, and flips the screen-content
    /// gate so the app stops blocking. Runs at most one probe at a time.
    private func autoConfirmScreenContentIfPossible() {
        guard !isAutoConfirmingScreenContent else { return }
        isAutoConfirmingScreenContent = true
        Task {
            let succeeded = (try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)) != nil
            await MainActor.run {
                self.isAutoConfirmingScreenContent = false
                guard succeeded, !self.hasScreenContentPermission else { return }
                self.hasScreenContentPermission = true
                UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                print("✅ Screen content auto-confirmed (Screen Recording is granted).")
                if self.hasCompletedOnboarding && self.allPermissionsGranted
                    && !self.isOverlayVisible && self.isClickyCursorEnabled {
                    self.overlayWindowManager.hasShownOverlayBefore = true
                    self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                    self.isOverlayVisible = true
                }
            }
        }
    }

    @Published private(set) var isRequestingScreenContent = false

    /// Triggers the macOS screen content picker by performing a dummy capture.
    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAllPermissions() }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in self?.currentAudioPowerLevel = powerLevel }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                guard self.voiceState != .responding else { return }
                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in self?.handleShortcutTransition(transition) }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard !showOnboardingVideo else { return }

            transientHideTask?.cancel()
            transientHideTask = nil

            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            currentResponseTask?.cancel()
            currentResponseTask = nil
            currentResponseIdentifier = nil
            speechSynthesizer.stopPlayback()
            clearDetectedElementLocation()
            lastResponseLatencyDescription = nil

            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) { onboardingPromptOpacity = 0.0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        print("🗣️ LocalClicky received transcript: \(finalTranscript)")
                        self.sendTranscriptToLocalModel(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - AI Response Pipeline (fully local)

    /// Captures a screenshot, sends it with the transcript to the local vision
    /// model, plays the spoken answer via on-device TTS, and — if the model
    /// returned a [POINT:x,y] tag — flies the blue cursor to that element.
    private func sendTranscriptToLocalModel(transcript: String) {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentResponseIdentifier = nil
        speechSynthesizer.stopPlayback()

        let responseIdentifier = UUID()
        currentResponseIdentifier = responseIdentifier
        currentResponseTask = Task {
            voiceState = .processing
            defer {
                if currentResponseIdentifier == responseIdentifier {
                    currentResponseTask = nil
                    currentResponseIdentifier = nil
                }
            }

            do {
                // Route this turn. The router decides screen vs text vs browser
                // command, so a self-contained follow-up ("add two to that")
                // doesn't trigger a screenshot + screen-grounded prompt the way
                // it used to. Browser commands are handled before any capture.
                let route = ConversationRouter.route(
                    transcript: transcript,
                    context: ConversationRouter.Context(
                        visionModeSelected: !isTextOnlyMode,
                        screenAvailable: hasScreenContentPermission,
                        previousTurnUsedScreen: previousTurnUsedScreen,
                        hasConversationHistory: !conversationHistory.isEmpty
                    )
                )

                // A browser command ("open gmail and start a draft") is an action,
                // not a question — hand it to the executor and we're done.
                if route == .browserCommand {
                    await handleBrowserCommand(transcript: transcript)
                    if !Task.isCancelled {
                        voiceState = .idle
                        scheduleTransientHideIfNeeded()
                    }
                    return
                }

                let useScreen = (route == .screen)

                var cursorScreenCapture: CompanionScreenCapture?
                let systemPrompt: String
                var userImagesBase64: [String] = []
                let model: String

                if useScreen, let capture = try? await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG() {
                    cursorScreenCapture = capture
                    userImagesBase64 = [capture.imageData.base64EncodedString()]
                    systemPrompt = LocalPrompts.screenVoiceResponse(
                        imageWidthInPixels: capture.screenshotWidthInPixels,
                        imageHeightInPixels: capture.screenshotHeightInPixels
                    )
                    model = LocalModels.visionModel
                } else {
                    systemPrompt = LocalPrompts.textVoiceResponse
                    model = LocalModels.chatModel
                }

                guard !Task.isCancelled else { return }

                var messages: [OllamaChatMessage] = [.system(systemPrompt)]
                for exchange in conversationHistory {
                    messages.append(.user(exchange.userTranscript))
                    messages.append(.assistant(exchange.assistantResponse))
                }
                messages.append(.user(transcript, imagesBase64: userImagesBase64))

                // Stream the answer and speak it sentence-by-sentence as it
                // arrives, so the companion starts talking before the whole
                // answer finishes generating. A single serial consumer task
                // speaks each ready sentence in order; the pointing tag is never
                // spoken (speakablePrefix stops at it).
                let (sentenceStream, sentenceContinuation) = AsyncStream<String>.makeStream()
                let speechProgress = StreamingSpeechProgress()
                defer { sentenceContinuation.finish() }

                let speakingTask = Task { @MainActor [weak self] in
                    for await sentence in sentenceStream {
                        if Task.isCancelled { break }
                        guard let self else { break }
                        do { try await self.speechSynthesizer.speakText(sentence) }
                        catch is CancellationError { break }
                        catch { print("⚠️ TTS error: \(error)") }
                    }
                }

                let result = try await ollamaClient.streamChat(
                    model: model,
                    messages: messages,
                    temperature: cursorScreenCapture == nil ? 0.7 : 0.3,
                    maxTokens: cursorScreenCapture == nil ? 220 : 180,
                    contextWindow: cursorScreenCapture == nil ? 4096 : 8192,
                    onText: { accumulated in
                        let speakable = SpokenTextSegmenter.speakablePrefix(accumulated)
                        if let (sentence, _) = speechProgress.advance(speakable: speakable) {
                            sentenceContinuation.yield(sentence)
                        }
                    }
                )

                guard !Task.isCancelled else {
                    sentenceContinuation.finish()
                    speakingTask.cancel()
                    return
                }

                let pointing = PointingTagParser.parse(from: result.text)
                let spokenText = pointing.spokenText

                // Flush the final sentence (no trailing space, so not emitted
                // during streaming), then close the stream so the speaker drains.
                let remainder = speechProgress.remainder(
                    speakable: SpokenTextSegmenter.speakablePrefix(result.text))
                if !remainder.isEmpty { sentenceContinuation.yield(remainder) }
                sentenceContinuation.finish()

                // Switch to idle BEFORE setting the location so the triangle is
                // visible and can fly to the target.
                if pointing.hasPoint { voiceState = .idle }

                if let center = pointing.centerInImagePixels, let capture = cursorScreenCapture {
                    let globalLocation = globalScreenLocation(forImagePoint: center, in: capture)
                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = capture.displayFrame
                    print("🎯 Pointing at \"\(pointing.label ?? "element")\" → (\(Int(center.x)), \(Int(center.y))) px")
                }

                conversationHistory.append((userTranscript: transcript, assistantResponse: spokenText))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }
                // Remember whether we actually looked at the screen, so the next
                // turn's router can read pronouns correctly.
                previousTurnUsedScreen = (cursorScreenCapture != nil)

                lastResponseLatencyDescription = formatLatencyBadge(result)

                // Wait until every sentence has been synthesized and queued, then
                // reflect that we're speaking.
                await speakingTask.value
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    voiceState = .responding
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted.
                if !buddyDictationManager.isDictationInProgress {
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                }
            } catch let error as OllamaError {
                print("⚠️ Local model error: \(error.localizedDescription)")
                refreshLocalEngineStatus()
                speakErrorFallback()
            } catch {
                print("⚠️ Companion response error: \(error)")
                speakErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Handles a spoken browser command by planning concrete URLs and opening
    /// them in the default browser, then speaking a short confirmation. Every
    /// action is plain navigation (reversible, nothing destructive), so it runs
    /// without a confirmation prompt — the executor can't do anything riskier.
    private func handleBrowserCommand(transcript: String) async {
        let plan = BrowserCommandPlanner.plan(for: transcript)
        if plan.isUnderstood {
            let opened = BrowserActionExecutor.execute(plan)
            print("🌐 Browser: opened \(opened)/\(plan.actions.count) — \(plan.actions.map { $0.label }.joined(separator: ", "))")
        }

        conversationHistory.append((userTranscript: transcript, assistantResponse: plan.spokenSummary))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        previousTurnUsedScreen = false

        voiceState = .responding
        do { try await speechSynthesizer.speakText(plan.spokenSummary) }
        catch { print("⚠️ TTS error during browser command: \(error)") }
    }

    /// Converts a point in the screenshot's pixel space (top-left origin) to a
    /// global AppKit screen coordinate (bottom-left origin) on the captured
    /// display. This is the same mapping the original used for cloud coords.
    private func globalScreenLocation(forImagePoint point: CGPoint, in capture: CompanionScreenCapture) -> CGPoint {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        let clampedX = max(0, min(point.x, screenshotWidth))
        let clampedY = max(0, min(point.y, screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    private func formatLatencyBadge(_ result: OllamaChatResult) -> String? {
        guard let firstToken = result.firstTokenLatencySeconds else { return nil }
        var description = String(format: "local · %.1fs", firstToken)
        if let tokensPerSecond = result.tokensPerSecond {
            description += String(format: " · %.0f tok/s", tokensPerSecond)
        }
        return description
    }

    /// If the cursor is in transient mode, waits for TTS + any pointing
    /// animation to finish, then fades the overlay out after a 1s pause.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }
        transientHideTask?.cancel()
        transientHideTask = Task {
            while speechSynthesizer.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a short on-device error line when the local model can't answer
    /// (Ollama not running, model missing, etc.).
    private func speakErrorFallback() {
        let utterance = isLocalEngineReachable
            ? "hmm, my local brain hiccuped. give it another try."
            : "my local engine isn't running. start ollama and i'll be right back."
        voiceState = .responding
        Task { try? await speechSynthesizer.speakText(utterance) }
    }

    // MARK: - Onboarding (fully local)

    /// LocalClicky has no cloud onboarding video. Instead, on first run the
    /// overlay does a short local demo: the cursor points at something on screen
    /// (via the local vision model), then the intro prompt streams in.
    func setupOnboardingVideo() {
        showOnboardingVideo = false
        onboardingVideoOpacity = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.performOnboardingDemoInteraction()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
            self?.startOnboardingPromptStream()
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        onboardingVideoPlayer = nil
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0
        withAnimation(.easeIn(duration: 0.4)) { onboardingPromptOpacity = 1.0 }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) { self.onboardingPromptOpacity = 0.0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Captures a screenshot and asks the local vision model to find something
    /// fun to point at, then flies the buddy there. Local replacement for the
    /// cloud onboarding demo.
    func performOnboardingDemoInteraction() {
        guard voiceState == .idle || voiceState == .responding else { return }
        guard hasScreenContentPermission else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else { return }

                let systemPrompt = LocalPrompts.onboardingDemo(
                    imageWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
                    imageHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
                )
                let result = try await ollamaClient.streamChat(
                    model: LocalModels.visionModel,
                    messages: [
                        .system(systemPrompt),
                        .user("look around my screen and find something interesting to point at",
                              imagesBase64: [cursorScreenCapture.imageData.base64EncodedString()]),
                    ],
                    temperature: 0.4,
                    maxTokens: 120,
                    onText: { _ in }
                )

                let pointing = PointingTagParser.parse(from: result.text)
                guard let center = pointing.centerInImagePixels else { return }

                detectedElementBubbleText = pointing.spokenText
                detectedElementScreenLocation = globalScreenLocation(forImagePoint: center, in: cursorScreenCapture)
                detectedElementDisplayFrame = cursorScreenCapture.displayFrame
                print("🎯 Onboarding demo: pointing at \"\(pointing.label ?? "element")\" — \"\(pointing.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}

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

    // MARK: - Blue side-text (cursor-adjacent text, independent of pointing)

    /// Text shown in the blue bubble beside the cursor *without* flying anywhere.
    /// This is the channel for the first-run intro, the screen-aware joke, the
    /// "give me X in text" answers, and the autotune model recommendation. nil
    /// means hidden. BlueCursorView observes it and renders it next to the cursor.
    @Published var companionSideText: String?
    @Published var companionSideTextOpacity: Double = 0.0
    /// Cancels an in-progress side-text streamer (so a new one, or push-to-talk,
    /// doesn't race a half-finished message).
    private var sideTextStreamTask: Task<Void, Never>?

    /// Provider + first-token latency for the most recent response, shown as a
    /// small badge near the cursor ("local · 0.6s · 41 tok/s"). Cleared when the
    /// next push-to-talk begins.
    @Published private(set) var lastResponseLatencyDescription: String?

    /// The detected hardware + the advisor's recommendation for this machine
    /// (drives the resident-model set, keep_alive, and the Phase 5 blue-text
    /// recommendation). Refreshed at launch.
    @Published private(set) var hardwareProfile: HardwareProfile = HardwareAdvisor.detect()
    @Published private(set) var hardwareRecommendation: ModelRecommendation = HardwareAdvisor.recommendForThisMachine()
    /// Whether the optional `autotune` CLI is installed (hybrid mode). The app is
    /// fully functional without it; when present it enriches the recommendation.
    @Published private(set) var autotuneStatus: AutotuneStatus = .notInstalled

    /// Whether the local Ollama server is reachable. Drives the panel nudge to
    /// start Ollama if it isn't running.
    @Published private(set) var isLocalEngineReachable = true
    /// Required models that aren't installed yet (so the panel can show the
    /// exact `ollama pull` to run).
    @Published private(set) var missingLocalModels: [String] = []

    /// The Ollama model powering each role. Defaults to LocalClicky's bundled
    /// choices; the user can repoint either at any installed model that's capable
    /// of the role (see the model picker). Persisted via ModelPreferences.
    @Published private(set) var chatModelName: String = ModelPreferences.chatModel
    @Published private(set) var visionModelName: String = ModelPreferences.visionModel
    /// The grounding model used for *pointing* turns (the blue cursor's
    /// coordinates). The default vision model (Moondream) can't ground, so
    /// pointing routes here. Loaded on demand unless the advisor keeps it
    /// resident (see warm-up + Phase 4 residency).
    @Published private(set) var groundingModelName: String = ModelPreferences.groundingModel

    /// Every model installed in the user's Ollama, for the model picker, plus the
    /// subset that can accept images — so the vision role can only ever be filled
    /// by a model that can actually see the screen.
    @Published private(set) var installedModels: [InstalledOllamaModel] = []
    @Published private(set) var visionCapableModelNames: Set<String> = []
    /// Models that can generate text (excludes embedding-only models), so the
    /// text-role picker never offers something that can't hold a conversation.
    @Published private(set) var chatCapableModelNames: Set<String> = []

    /// The companion's most recent real spoken answer, for the "copy your answer"
    /// clipboard action. Set only by the text/vision answer path (not by browser
    /// or app-launch actions), so "copy that" always grabs the actual answer.
    private var lastSpokenAnswer: String?

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
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission
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
            presentOverlayAndIntroIfNeeded()
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the first-run intro (blue-text greeting + screen-aware joke) has
    /// already played. Replaces the old onboarding flag — there is no onboarding
    /// video or music anymore.
    var hasSeenIntro: Bool {
        get { UserDefaults.standard.bool(forKey: "hasSeenIntro") }
        set { UserDefaults.standard.set(newValue, forKey: "hasSeenIntro") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 LocalClicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), introSeen: \(hasSeenIntro)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        refreshLocalEngineStatus()

        // Pay one-time warm-up costs now, in the background, so the user's first
        // interaction is snappy: the neural voice's inference graph, and both
        // Ollama models loaded and resident (keep_alive keeps them warm).
        refreshHardwareRecommendation()
        refreshOllamaInstalled()
        speechSynthesizer.warmUp()
        warmUpLocalModels()
        refreshInstalledModels()

        // Permissions granted → show the cursor now (and, on first launch, play
        // the intro + screen-aware joke in the blue side-text beside the cursor).
        if allPermissionsGranted && isClickyCursorEnabled {
            presentOverlayAndIntroIfNeeded()
            // A bit later, gently suggest a better-fit model if there is one —
            // non-invasive blue text, shown at most once per distinct suggestion,
            // and skipped while the intro/joke is still on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
                self?.maybeShowModelRecommendation()
            }
        }
    }

    /// True once the recommendation has been shown this launch (don't repeat it).
    private var hasShownRecommendationThisLaunch = false

    /// Non-invasive autotune-style recommendation: if the advisor's best-fit
    /// models for this Mac differ from what's currently selected, gently suggest
    /// the switch in the blue side-text. Shown at most once per distinct
    /// recommendation (a UserDefaults signature prevents nagging across launches),
    /// never while other side-text is up, and it auto-dismisses — it can't block
    /// anything. Credits `autotune` when the CLI is installed.
    func maybeShowModelRecommendation() {
        guard isOverlayVisible, companionSideText == nil, !hasShownRecommendationThisLaunch else { return }
        let rec = hardwareRecommendation
        let differs = (chatModelName != rec.chatModel) || (visionModelName != rec.visionModel)
        guard differs else { return }

        let target = chatModelName != rec.chatModel ? rec.chatModel : rec.visionModel
        let source = autotuneStatus.isInstalled ? "autotune" : "tip"
        let gb = Int(hardwareProfile.totalRAMGB.rounded())
        let message = "\(source): \(target) is a great fit for your \(gb) gb mac — switch it in the menu-bar panel under models."

        let signature = "\(rec.chatModel)|\(rec.visionModel)"
        let key = "localClicky.lastRecommendationShown"
        guard UserDefaults.standard.string(forKey: key) != signature else { return }
        UserDefaults.standard.set(signature, forKey: key)
        hasShownRecommendationThisLaunch = true
        streamSideText(message, characterInterval: 0.02, holdSeconds: 9, autoDismiss: true)
    }

    /// Shows the cursor overlay and, the very first time, kicks off the blue-text
    /// intro + screen-aware joke. Kept in one place so every path that first
    /// reveals the cursor (launch, cursor toggle, permission grant) plays the
    /// intro exactly once.
    private func presentOverlayAndIntroIfNeeded() {
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
        guard !hasSeenIntro else { return }
        // Small delay so the cursor has faded in before the intro starts typing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.playFirstRunIntro()
        }
    }

    /// Sends a tiny throwaway request to each selected local model so Ollama loads
    /// it into memory before the first real question. With keep_alive they stay
    /// resident, turning a cold multi-second first answer into a warm one. The
    /// context window matches what the real requests use (and is identical across
    /// roles) so Ollama never reloads a model for a different num_ctx — which also
    /// matters when one model is picked for both roles.
    private func warmUpLocalModels() {
        // Warm the models the app will actually use, each at the context window
        // it will be called with (so Ollama never reloads it for a different
        // num_ctx) and with the advisor's keep_alive so they stay resident. The
        // grounding model is warmed too only when the advisor says it fits
        // alongside the others — otherwise it loads on demand for pointing turns.
        var toWarm: [(model: String, ctx: Int)] = [
            (chatModelName, contextWindow(forModel: chatModelName)),
            (visionModelName, contextWindow(forModel: visionModelName)),
        ]
        if hardwareRecommendation.keepsGroundingResident {
            toWarm.append((groundingModelName, contextWindow(forModel: groundingModelName)))
        }
        var seen = Set<String>()
        let unique = toWarm.filter { seen.insert($0.model).inserted }
        let keepAlive = hardwareRecommendation.keepAlive
        Task.detached(priority: .utility) { [ollamaClient] in
            for entry in unique {
                _ = try? await ollamaClient.streamChat(
                    model: entry.model,
                    messages: [.user("hi")],
                    temperature: 0.0,
                    maxTokens: 1,
                    keepAlive: keepAlive,
                    contextWindow: entry.ctx,
                    onText: { _ in }
                )
            }
        }
    }

    /// The context window to use for a given model. Vision/grounding models get
    /// the roomy window (screenshot + history); a pure text model gets a snug one
    /// (faster prefill, less KV RAM). Checking against the *current* role models
    /// keeps it reload-safe: a model always gets one consistent value, including
    /// when a single VLM fills both the text and vision roles.
    private func contextWindow(forModel model: String) -> Int {
        if model == visionModelName || model == groundingModelName {
            return LocalModels.visionContextWindow
        }
        return LocalModels.textContextWindow
    }

    /// Recomputes the hardware profile + recommendation, and (in the background)
    /// detects the optional autotune CLI. Cheap; safe to call on launch and after
    /// the user changes models.
    func refreshHardwareRecommendation() {
        hardwareProfile = HardwareAdvisor.detect()
        hardwareRecommendation = HardwareAdvisor.recommend(for: hardwareProfile)
        Task.detached(priority: .utility) {
            let status = AutotuneBridge.quickStatus()
            await MainActor.run { self.autotuneStatus = status }
        }
    }

    /// Checks that the local Ollama server is up and the *selected* models are
    /// installed, so the panel can guide the user if not.
    func refreshLocalEngineStatus() {
        let selected = Array(Set([chatModelName, visionModelName]))
        Task {
            let reachable = await ollamaClient.isServerReachable()
            var missing: [String] = []
            if reachable {
                missing = (try? await ollamaClient.missingModels(selected)) ?? []
            }
            await MainActor.run {
                self.isLocalEngineReachable = reachable
                self.missingLocalModels = missing
            }
        }
    }

    /// Loads the list of installed Ollama models (for the model picker) and
    /// figures out which of them can accept images, so the vision role can only
    /// be filled by a vision-capable model.
    func refreshInstalledModels() {
        Task {
            guard let models = try? await ollamaClient.listInstalledModels(), !models.isEmpty else {
                return
            }
            var visionCapable = Set<String>()
            var chatCapable = Set<String>()
            for model in models {
                let capabilities = await ollamaClient.capabilities(of: model.name)
                if capabilities.contains("vision") { visionCapable.insert(model.name) }
                // "completion" means it generates text; embedding-only models don't.
                if capabilities.contains("completion") { chatCapable.insert(model.name) }
            }
            await MainActor.run {
                self.installedModels = models
                self.visionCapableModelNames = visionCapable
                self.chatCapableModelNames = chatCapable
            }
        }
    }

    /// Repoints a role at a different installed model, persists the choice, and
    /// warms the new model so the next answer is snappy. The picker only offers
    /// valid models per role, so no extra validation is needed here.
    func setModel(_ name: String, for role: ModelRole) {
        switch role {
        case .chat:
            guard name != chatModelName else { return }
            chatModelName = name
        case .vision:
            guard name != visionModelName else { return }
            visionModelName = name
        }
        ModelPreferences.setModel(name, for: role)
        warmUpLocalModels()
        refreshLocalEngineStatus()
    }

    /// The model to use for a pointing turn: the dedicated grounding model when
    /// it's installed, otherwise the main vision model (best effort — it may not
    /// actually ground). Kept in one place so the answer pipeline and any warm-up
    /// agree on which model pointing uses.
    private func resolvedGroundingModelName() -> String {
        guard !installedModels.isEmpty else { return groundingModelName }
        let names = installedModels.map { $0.name }
        return OllamaClient.modelInstalled(groundingModelName, among: names) ? groundingModelName : visionModelName
    }

    // MARK: - Model downloads + Ollama install

    /// Whether Ollama appears installed at all (distinct from "running").
    @Published private(set) var isOllamaInstalled: Bool = true
    /// The model currently downloading (nil when idle), its 0…1 progress, and a
    /// short status line ("downloading", "verifying", "ready").
    @Published private(set) var downloadingModelName: String?
    @Published private(set) var downloadFraction: Double = 0
    @Published private(set) var downloadStatusText: String?
    /// Ollama install flow state for the panel button.
    @Published private(set) var ollamaInstallInProgress = false
    @Published var ollamaInstallMessage: String?

    private var downloadTask: Task<Void, Never>?

    /// Curated models that both FIT this machine (resident footprint ≤ total RAM,
    /// with margin) and aren't installed yet — exactly what the download dropdown
    /// should offer. "Only download if it fits."
    var downloadableModels: [CatalogModel] {
        let installedNames = installedModels.map { $0.name }
        return ModelCatalog.all.filter { model in
            let alreadyInstalled = installedNames.contains { OllamaClient.modelInstalled(model.name, among: [$0]) }
            let fits = model.residentGB + 1.5 <= hardwareProfile.totalRAMGB
            return !alreadyInstalled && fits
        }
    }

    /// True if `name` is the advisor's recommended model for one of the roles
    /// (so the download dropdown can mark it).
    func isRecommendedModel(_ name: String) -> Bool {
        let rec = hardwareRecommendation
        return name == rec.chatModel || name == rec.visionModel || name == rec.groundingModel
    }

    func refreshOllamaInstalled() {
        isOllamaInstalled = OllamaInstaller.isInstalled()
    }

    /// One-click: download a model with streamed progress, then refresh the model
    /// lists and warm it straight into RAM so it's ready to use immediately.
    func downloadModel(_ name: String) {
        guard downloadingModelName == nil else { return }
        downloadingModelName = name
        downloadFraction = 0
        downloadStatusText = "starting…"
        let client = ollamaClient
        downloadTask = Task { [weak self] in
            do {
                for try await progress in client.pullModel(name) {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self?.downloadFraction = progress.fraction
                        self?.downloadStatusText = progress.status
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.downloadFraction = 1
                    self.downloadStatusText = "ready"
                    self.downloadingModelName = nil
                    self.refreshInstalledModels()
                    self.refreshLocalEngineStatus()
                    self.warmUpModel(name)   // resident + ready to use right away
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.downloadStatusText = nil }
                }
            } catch {
                await MainActor.run {
                    self?.downloadStatusText = "download failed — try again"
                    self?.downloadFraction = 0
                    self?.downloadingModelName = nil
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadingModelName = nil
        downloadStatusText = nil
        downloadFraction = 0
    }

    /// Warms a single model into memory (used right after a download completes).
    private func warmUpModel(_ name: String) {
        let ctx = contextWindow(forModel: name)
        let keepAlive = hardwareRecommendation.keepAlive
        let client = ollamaClient
        Task.detached(priority: .utility) {
            _ = try? await client.streamChat(
                model: name, messages: [.user("hi")], temperature: 0.0, maxTokens: 1,
                keepAlive: keepAlive, contextWindow: ctx, onText: { _ in })
        }
    }

    /// One-click Ollama setup: if it's installed but not running, launch it; if
    /// it's not installed, download + install the official app (with a browser
    /// fallback). Network here is the single user-initiated fetch from ollama.com.
    func installOrStartOllama() {
        guard !ollamaInstallInProgress else { return }
        if OllamaInstaller.isInstalled() {
            OllamaInstaller.launchInstalledApp()
            ollamaInstallMessage = "starting ollama…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.refreshLocalEngineStatus()
                self?.refreshOllamaInstalled()
                self?.warmUpLocalModels()
            }
            return
        }
        ollamaInstallInProgress = true
        ollamaInstallMessage = "downloading ollama…"
        Task { [weak self] in
            let outcome = await OllamaInstaller.install()
            await MainActor.run {
                guard let self else { return }
                self.ollamaInstallInProgress = false
                switch outcome {
                case .installedAndLaunched:
                    self.ollamaInstallMessage = "ollama installed — starting up…"
                case .openedDownloadPage:
                    self.ollamaInstallMessage = "opened the ollama download page — drag it to Applications, then reopen."
                case .failed(let detail):
                    self.ollamaInstallMessage = "couldn't install ollama: \(detail)"
                }
                self.refreshOllamaInstalled()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self.refreshLocalEngineStatus()
                    self.refreshOllamaInstalled()
                }
            }
        }
    }

    /// Restores both roles to LocalClicky's default models.
    func resetModelsToDefaults() {
        ModelPreferences.resetToDefaults()
        chatModelName = ModelPreferences.chatModel
        visionModelName = ModelPreferences.visionModel
        groundingModelName = ModelPreferences.groundingModel
        warmUpLocalModels()
        refreshLocalEngineStatus()
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    // MARK: - Blue side-text channel

    /// Fades out and clears any blue side-text shown beside the cursor.
    func dismissSideText() {
        sideTextStreamTask?.cancel()
        sideTextStreamTask = nil
        guard companionSideText != nil else { return }
        withAnimation(.easeOut(duration: 0.25)) { companionSideTextOpacity = 0.0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.companionSideTextOpacity == 0.0 else { return }
            self.companionSideText = nil
        }
    }

    /// Types `message` into the blue side-text bubble one character at a time
    /// (the signature streamed-text feel), holds it, then fades out — unless
    /// `autoDismiss` is false, in which case it stays until something replaces it.
    /// `onFinished` runs after the full message is on screen (used to chain the
    /// first-run intro into the screen-aware joke).
    func streamSideText(_ message: String,
                        characterInterval: TimeInterval = 0.03,
                        holdSeconds: TimeInterval = 6.0,
                        autoDismiss: Bool = true,
                        onFinished: (@MainActor () -> Void)? = nil) {
        sideTextStreamTask?.cancel()
        let characters = Array(message)
        companionSideText = ""
        companionSideTextOpacity = 0.0
        withAnimation(.easeIn(duration: 0.35)) { companionSideTextOpacity = 1.0 }

        sideTextStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var shown = ""
            for character in characters {
                if Task.isCancelled { return }
                shown.append(character)
                self.companionSideText = shown
                try? await Task.sleep(nanoseconds: UInt64(characterInterval * 1_000_000_000))
            }
            if Task.isCancelled { return }
            onFinished?()
            guard autoDismiss else { return }
            try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            self.dismissSideText()
        }
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
    }

    func requestAccessibilityPermission() {
        WindowPositionManager.requestAccessibilityPermission()
        refreshAllPermissions()
        schedulePermissionRefreshesAfterAccessibilityRequest()
    }

    func requestScreenRecordingPermission() {
        WindowPositionManager.requestScreenRecordingPermission()
        refreshAllPermissions()
        schedulePermissionRefreshesAfterScreenRecordingRequest()
    }

    func refreshAllPermissions() {
        let hadAllPermissionsBeforeRefresh = allPermissionsGranted
        UserDefaults.standard.removeObject(forKey: "hasScreenContentPermission")

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        let currentlyHasScreenRecording = WindowPositionManager.hasScreenRecordingPermission()
        let hadPreviouslyConfirmedScreenRecording = WindowPositionManager.hasPreviouslyConfirmedScreenRecordingPermission()
        hasScreenRecordingPermission = currentlyHasScreenRecording || hadPreviouslyConfirmedScreenRecording
        if !currentlyHasScreenRecording && hadPreviouslyConfirmedScreenRecording {
            verifyPreviouslyConfirmedScreenRecordingStillWorks()
        }

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        if !hadAllPermissionsBeforeRefresh
            && allPermissionsGranted
            && !isOverlayVisible
            && isClickyCursorEnabled {
            presentOverlayAndIntroIfNeeded()
        }
    }

    private func schedulePermissionRefreshesAfterAccessibilityRequest() {
        for delay in [0.4, 1.5, 3.0, 6.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func schedulePermissionRefreshesAfterScreenRecordingRequest() {
        for delay in [0.6, 2.0, 5.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private var isVerifyingPreviouslyConfirmedScreenRecording = false

    private func verifyPreviouslyConfirmedScreenRecordingStillWorks() {
        guard !isVerifyingPreviouslyConfirmedScreenRecording else { return }
        isVerifyingPreviouslyConfirmedScreenRecording = true
        Task {
            let canReadScreenContent = (try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)) != nil
            await MainActor.run {
                self.isVerifyingPreviouslyConfirmedScreenRecording = false
                guard !canReadScreenContent else { return }
                WindowPositionManager.clearPreviouslyConfirmedScreenRecordingPermission()
                self.hasScreenRecordingPermission = false
                print("⚠️ Screen Recording fallback was stale; cleared saved confirmation.")
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
            dismissSideText()
            lastResponseLatencyDescription = nil

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
                        screenAvailable: hasScreenRecordingPermission,
                        previousTurnUsedScreen: previousTurnUsedScreen,
                        hasConversationHistory: !conversationHistory.isEmpty
                    )
                )

                // Deterministic action requests (browser nav, launching an app,
                // copying the last answer) are handled before any screenshot —
                // they're actions, not questions, and each is structurally safe.
                if route == .browserCommand {
                    await handleBrowserCommand(transcript: transcript)
                    settleAfterAction()
                    return
                }
                if route == .openApp {
                    await handleOpenAppCommand(transcript: transcript)
                    settleAfterAction()
                    return
                }
                if route == .copyLastAnswer {
                    await handleCopyLastAnswer()
                    settleAfterAction()
                    return
                }
                if route == .showText {
                    await handleShowTextCommand(transcript: transcript)
                    settleAfterAction()
                    return
                }
                if route == .webReach {
                    await handleWebReachCommand(transcript: transcript)
                    settleAfterAction()
                    return
                }

                let useScreen = (route == .screen || route == .screenPoint)
                let wantsPointing = (route == .screenPoint)

                var cursorScreenCapture: CompanionScreenCapture?
                let systemPrompt: String
                var userImagesBase64: [String] = []
                let model: String

                if useScreen, let capture = try? await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG() {
                    cursorScreenCapture = capture
                    userImagesBase64 = [capture.imageData.base64EncodedString()]
                    if wantsPointing {
                        // Pointing turn: use the grounding model + the pointing
                        // prompt. If the resolved model can't ground (grounding
                        // model not installed and the vision model is Moondream),
                        // describe instead of asking it for empty coordinates.
                        let pointingModel = resolvedGroundingModelName()
                        if LocalModels.isLikelyGroundingCapable(pointingModel) {
                            systemPrompt = LocalPrompts.screenPointResponse(
                                imageWidthInPixels: capture.screenshotWidthInPixels,
                                imageHeightInPixels: capture.screenshotHeightInPixels)
                        } else {
                            systemPrompt = LocalPrompts.screenDescribe(
                                imageWidthInPixels: capture.screenshotWidthInPixels,
                                imageHeightInPixels: capture.screenshotHeightInPixels)
                        }
                        model = pointingModel
                    } else {
                        // Describe/answer turn: the default vision model (Moondream),
                        // which is strong at description but doesn't emit coordinates.
                        systemPrompt = LocalPrompts.screenDescribe(
                            imageWidthInPixels: capture.screenshotWidthInPixels,
                            imageHeightInPixels: capture.screenshotHeightInPixels)
                        model = visionModelName
                    }
                } else {
                    systemPrompt = LocalPrompts.textVoiceResponse
                    model = chatModelName
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
                    keepAlive: hardwareRecommendation.keepAlive,
                    contextWindow: contextWindow(forModel: model),
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
                // Remember the answer so "copy your answer" can put it on the
                // clipboard (only real answers — not browser/app confirmations).
                let trimmedSpoken = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedSpoken.isEmpty { lastSpokenAnswer = trimmedSpoken }
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

    /// Returns the companion to idle after a deterministic action (browser, app
    /// launch, clipboard), matching the rest of the pipeline. Kept in one place so
    /// every action route settles the same way.
    private func settleAfterAction() {
        if !Task.isCancelled {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    /// Opens a local macOS application by name ("launch spotify", "open the notes
    /// app"). Resolves the spoken name to an app that's actually installed; if
    /// nothing matches it gracefully falls back to a browser navigation for the
    /// same words (so "launch youtube", which has no app, still opens the site),
    /// and only then says it couldn't find it. Launching an installed app is as
    /// safe as double-clicking it in Finder.
    private func handleOpenAppCommand(transcript: String) async {
        let spokenName = AppCommandPlanner.appLaunchName(from: transcript) ?? transcript
        let summary: String

        if let launchedName = LocalAppLauncher.launchApp(named: spokenName) {
            summary = "opening \(launchedName.lowercased()) for you."
            print("🚀 App: launched \(launchedName)")
        } else {
            // No installed app matched — try the same words as a web destination
            // before giving up, so we still do something useful when we can.
            let browserPlan = BrowserCommandPlanner.plan(for: transcript)
            if browserPlan.isUnderstood {
                BrowserActionExecutor.execute(browserPlan)
                summary = browserPlan.spokenSummary
                print("🌐 App not found; opened web fallback for \(spokenName)")
            } else {
                summary = "i couldn't find an app called \(spokenName) on your mac."
                print("🚫 App: no match for \(spokenName)")
            }
        }

        conversationHistory.append((userTranscript: transcript, assistantResponse: summary))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        previousTurnUsedScreen = false

        voiceState = .responding
        do { try await speechSynthesizer.speakText(summary) }
        catch { print("⚠️ TTS error during app command: \(error)") }
    }

    /// Copies the companion's last real spoken answer to the system clipboard.
    /// Useful right after asking it to write, translate, or summarize something.
    private func handleCopyLastAnswer() async {
        let summary: String
        if let answer = lastSpokenAnswer, !answer.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(answer, forType: .string)
            summary = "copied that to your clipboard."
            print("📋 Clipboard: copied \(answer.count) chars")
        } else {
            summary = "i don't have an answer to copy yet. ask me something first."
        }

        previousTurnUsedScreen = false
        voiceState = .responding
        do { try await speechSynthesizer.speakText(summary) }
        catch { print("⚠️ TTS error during clipboard command: \(error)") }
    }

    /// Answers a "give me X in text" command: a concise, honest answer rendered
    /// in the blue side-text beside the cursor (and spoken). Uses the fast text
    /// model; the conciseText prompt forces brevity and forbids made-up facts.
    private func handleShowTextCommand(transcript: String) async {
        voiceState = .processing
        var answer = ""
        do {
            let result = try await ollamaClient.streamChat(
                model: chatModelName,
                messages: [.system(LocalPrompts.conciseText), .user(transcript)],
                temperature: 0.2,
                maxTokens: 64,
                keepAlive: hardwareRecommendation.keepAlive,
                contextWindow: contextWindow(forModel: chatModelName),
                onText: { _ in })
            answer = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            return
        } catch {
            print("⚠️ give-text error: \(error)")
            refreshLocalEngineStatus()
        }

        conversationHistory.append((userTranscript: transcript, assistantResponse: answer))
        if conversationHistory.count > 10 { conversationHistory.removeFirst(conversationHistory.count - 10) }
        previousTurnUsedScreen = false

        guard !answer.isEmpty else {
            streamSideText("hmm, i couldn't get that one. try asking again.", holdSeconds: 5, autoDismiss: true)
            return
        }
        lastSpokenAnswer = answer
        // Blue text is the primary output for this command; also speak it since
        // LocalClicky is voice-first.
        streamSideText(answer, characterInterval: 0.02, holdSeconds: 10, autoDismiss: true)
        voiceState = .responding
        do { try await speechSynthesizer.speakText(answer) }
        catch { print("⚠️ TTS error during give-text: \(error)") }
    }

    // MARK: - Web reach (the one opt-in internet feature)

    /// Answers an internet-needing question: fetches web results via WebReachTool
    /// (Jina Reader — the one documented cloud call), then has the local text
    /// model synthesize a spoken answer grounded only in what was fetched. Shows
    /// "checking the web…" in the blue text first, since this is the single
    /// feature that leaves the no-cloud guarantee.
    private func handleWebReachCommand(transcript: String) async {
        voiceState = .processing
        streamSideText("checking the web…", autoDismiss: false)

        let results = await WebReachTool.search(transcript)
        guard !Task.isCancelled else { dismissSideText(); return }

        guard let results, !results.isEmpty else {
            dismissSideText()
            previousTurnUsedScreen = false
            let message = "i couldn't reach the web just now — check your connection and try again."
            voiceState = .responding
            do { try await speechSynthesizer.speakText(message) }
            catch { print("⚠️ TTS error during web-reach: \(error)") }
            return
        }

        var answer = ""
        do {
            let synthesis = try await ollamaClient.streamChat(
                model: chatModelName,
                messages: [.system(LocalPrompts.webAnswer),
                           .user("question: \(transcript)\n\nweb results:\n\(results)")],
                temperature: 0.3,
                maxTokens: 180,
                keepAlive: hardwareRecommendation.keepAlive,
                contextWindow: contextWindow(forModel: chatModelName),
                onText: { _ in })
            answer = synthesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            dismissSideText(); return
        } catch {
            print("⚠️ web-reach synthesis error: \(error)")
            refreshLocalEngineStatus()
        }

        dismissSideText()
        conversationHistory.append((userTranscript: transcript, assistantResponse: answer))
        if conversationHistory.count > 10 { conversationHistory.removeFirst(conversationHistory.count - 10) }
        previousTurnUsedScreen = false

        guard !answer.isEmpty else {
            let message = "i found some pages but couldn't pull an answer out of them."
            voiceState = .responding
            do { try await speechSynthesizer.speakText(message) }
            catch { print("⚠️ TTS error during web-reach: \(error)") }
            return
        }
        lastSpokenAnswer = answer
        voiceState = .responding
        do { try await speechSynthesizer.speakText(answer) }
        catch { print("⚠️ TTS error during web-reach: \(error)") }
    }

    // MARK: - First-run intro (blue side-text) + screen-aware joke

    /// First launch only: streams a short self-intro in the blue side-text while,
    /// in parallel, grabbing the screen; when the intro finishes, drops a
    /// screen-aware joke into the same blue text (and speaks it).
    func playFirstRunIntro() {
        // Capture + joke generation start immediately, in parallel with the intro
        // streaming — so the joke is usually ready by the time the intro ends.
        let jokeTask = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.generateScreenJoke()
        }

        let intro = "hey, i'm localclicky — your on-device mac buddy. hold control and option to talk to me, and i'll answer out loud and fly my blue cursor to things on your screen. everything runs locally on your mac, no cloud. one sec, let me see what you're up to…"
        streamSideText(intro, characterInterval: 0.026, autoDismiss: false) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let joke = await jokeTask.value
                // If the user already started talking (side text cleared), don't barge in.
                guard self.companionSideText != nil else { return }
                if let joke, !joke.isEmpty {
                    self.streamSideText(joke, characterInterval: 0.03, holdSeconds: 9, autoDismiss: true)
                    self.voiceState = .responding
                    do { try await self.speechSynthesizer.speakText(joke) }
                    catch { /* a missing voice shouldn't break the intro */ }
                    self.voiceState = .idle
                } else {
                    self.dismissSideText()
                }
            }
        }
    }

    /// Captures the screen and produces a one-line, screen-aware joke via a
    /// two-step pipeline: the vision model glances (a simple describe it can
    /// actually do), then the wittier text model turns that into the joke.
    /// Returns nil if the screen isn't available or both steps fail.
    private func generateScreenJoke() async -> String? {
        guard hasScreenRecordingPermission else { return nil }
        guard let capture = try? await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG() else { return nil }

        // Step 1 — vision model glance (simple imperative; reliable on Moondream).
        let glance = try? await ollamaClient.streamChat(
            model: visionModelName,
            messages: [.system(LocalPrompts.screenGlanceSystem),
                       .user(LocalPrompts.screenGlanceUser,
                             imagesBase64: [capture.imageData.base64EncodedString()])],
            temperature: 0.3,
            maxTokens: 60,
            keepAlive: hardwareRecommendation.keepAlive,
            contextWindow: contextWindow(forModel: visionModelName),
            onText: { _ in })
        var description = glance?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The small vision model occasionally returns empty/garbage; fall back to
        // a generic-but-still-screen-aware description so the joke still lands.
        if description.count < 8 { description = "their computer screen with a few things open" }

        // Step 2 — text model turns the description into a witty one-liner.
        let joke = try? await ollamaClient.streamChat(
            model: chatModelName,
            messages: [.system(LocalPrompts.screenJokeFromDescription),
                       .user("the user is looking at: \(description). make the joke.")],
            temperature: 0.9,
            maxTokens: 50,
            keepAlive: hardwareRecommendation.keepAlive,
            contextWindow: contextWindow(forModel: chatModelName),
            onText: { _ in })
        return joke?.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

}

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

    /// "Let Clicky draw (beta)": when on, a turn that asks to circle, outline,
    /// underline, highlight or mark something goes to the shape route. Off by
    /// default; with it off, routing is exactly what it was.
    @Published private(set) var drawingEnabled: Bool = ModelPreferences.drawingEnabled

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
    /// The live ink trail drawn on every overlay while the keys are held.
    let inkTrail = InkTrailModel()
    /// The assistant's own marks (circle, arrow, highlight...) drawn on the
    /// overlays while it speaks. Only filled when the drawing setting is on.
    let assistantMarks = AssistantMarksModel()

    // MARK: - Local inference

    /// The single client for the local Ollama server. All chat and vision
    /// requests go here — there is no cloud client anywhere in this app.
    private let ollamaClient = OllamaClient()

    /// On-device voice. Prefers the natural-sounding neural Piper voice and
    /// falls back to Apple's synthesizer if it's unavailable. Replaces the cloud
    /// TTS; works with the network off.
    private let speechSynthesizer = SpeechSynthesisCoordinator()

    /// In-app countdown timers ("set a timer for 4 minutes"). Announces out loud
    /// when each one finishes.
    private let timerService = TimerService()

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

    /// Stage timing for the turn in progress, from key down to the cursor
    /// landing. Timings only, never the question or the answer (see TurnTimer).
    private var turnTimer: TurnTimer?
    /// Set once a turn's response task has ended. While the cursor is still in
    /// flight the record stays open: it is written on arrival, or by the flush
    /// timeout.
    private var finishedTurnOutcome: String?
    private var turnRecordFlushTask: Task<Void, Never>?

    /// A click turn clicks after the cursor lands, not after a fixed delay.
    private var clickGate = ClickGate()
    private var pendingClickCGPoint: CGPoint?
    private var clickFallbackTask: Task<Void, Never>?

    /// The screenshot started at key press, in parallel with listening. The
    /// transcript handler claims it (and clears this); a press that ends with no
    /// transcript, or a newer press, discards it. It lives only in memory.
    private struct PressCapture {
        let task: Task<CompanionScreenCapture?, Never>
        let startedAtNanoseconds: UInt64
    }
    private var pressCapture: PressCapture?

    /// The user's ink prepared for this turn (analysis, composite, close-up and
    /// Accessibility harvest). Started at key up so it overlaps the transcript
    /// finalising; the transcript handler claims it, and a press that ends with
    /// no transcript, or a newer press, discards it. Only in memory.
    private var pendingInkTask: Task<InkTurnPackage?, Never>?

    /// Decides when an idle voice state means the press was abandoned and its
    /// capture and ink can go (see bindVoiceStateObservation).
    private lazy var pressCaptureLifetime = PressCaptureLifetime(
        isSettledIdle: { [unowned self] in !buddyDictationManager.isDictationInProgress },
        discard: { [unowned self] in discardPressCapture() }
    )

    /// Pointing state for one response, touched only on the main actor. It lets
    /// the stream-end path know whether the cursor already left early, and stops
    /// a late early-dispatch from running after the final parse took over.
    private final class TurnPointingState {
        var earlyDispatchedImagePoint: CGPoint?
        /// Where the early flight went (global AppKit points, after the snap): a click turn clicks there.
        var earlyDispatchedLocation: CGPoint?
        var isFinalized = false
        /// The snap of the early point, running or done. The final path awaits it when the stream ended before
        /// the early flight, so one point is never snapped (harvested) twice.
        var earlySnap: Task<CGPoint, Never>?
    }

    /// What the pointing step of one turn knows besides the model's point: the words the model got, the
    /// object put into them for a follow-up, and whether the request names a window (the snap picks the
    /// window's title bar for one, an Accessibility element for anything else).
    private struct PointingTurnInfo: Sendable {
        let transcript: String
        let substitutedObject: String?
        /// The requested object ("the chat window"): the substituted one, else the words' own. Nil when none.
        let object: String?
        let namesWindow: Bool
    }

    /// The noun phrase of the last pointing or click request ("the chat window"), for "point out to me again"
    /// (PointingFollowUp). Replaced by the next request that has an object of its own.
    private var lastPointingObject: String?
    /// The previous turn pointed at or clicked something, so a bare "again" or "that one" points too.
    private var previousTurnWasPointing = false
    /// Marks were on screen (or waiting for their sentence) when the key was pressed. The press clears them
    /// before the words are heard, so "clear the tic tac toe" needs this to know there was a drawing to clear.
    private var marksShownAtPress = false

    /// The current drawing turn's marks waiting for their sentence to be
    /// spoken (SpeechMarkScheduler), the task that shows them when due, and the
    /// base the next turn's speech clip ids start from (so a late clip start
    /// from an earlier turn can never match this turn's marks).
    private var markScheduler: SpeechMarkSchedulerBox<InkDrawing>?
    private var markDriverTask: Task<Void, Never>?
    private var nextClipIDBase = 1

    private var marksClearTask: Task<Void, Never>?
    /// How long the next marks hold after the speech ends; nil is the palette's own hold. A sketch sets it.
    private var marksHoldSeconds: Double?

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
        timerService.onTimerFinished = { [weak self] spokenDuration in
            guard let self else { return }
            let message = "time's up — your \(spokenDuration) timer is done."
            self.streamSideText(message, holdSeconds: 8, autoDismiss: true)
            self.voiceState = .responding
            Task { try? await self.speechSynthesizer.speakText(message); self.voiceState = .idle }
        }
        refreshAllPermissions()
        print("🔑 LocalClicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), introSeen: \(hasSeenIntro)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        buddyDictationManager.onListeningStarted = { [weak self] in self?.turnTimer?.mark(.listeningStarted) }
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
        // Mark it seen now so the greeting + joke play exactly once, ever — not on
        // every launch. (Persisted immediately rather than after the async intro so
        // a quick relaunch can't replay it.)
        hasSeenIntro = true
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
        case .grounding:
            guard name != groundingModelName else { return }
            groundingModelName = name
        }
        ModelPreferences.setModel(name, for: role)
        warmUpLocalModels()
        refreshLocalEngineStatus()
    }

    func setDrawingEnabled(_ enabled: Bool) {
        guard enabled != drawingEnabled else { return }
        drawingEnabled = enabled
        ModelPreferences.drawingEnabled = enabled
        if !enabled { assistantMarks.clearNow() }
    }

    /// The model to use for a pointing turn: the dedicated grounding model when
    /// it's installed, otherwise the main vision model (best effort — it may not
    /// actually ground). Kept in one place so the answer pipeline and any warm-up
    /// agree on which model pointing uses.
    /// True when the chosen pointing model is not installed, so pointing and
    /// drawing turns fall back to the Vision model. The panel shows a note.
    var groundingFallsBackToVision: Bool {
        !installedModels.isEmpty && resolvedGroundingModelName() != groundingModelName
    }

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
        cancelPendingMarks()
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
        let destination = WindowPositionManager.requestScreenRecordingPermission()
        if destination != .alreadyGranted {
            markScreenRecordingGrantPendingFreshProcess()
        }
        refreshAllPermissions()
        schedulePermissionRefreshesAfterScreenRecordingRequest()
        if destination != .alreadyGranted {
            scheduleAutomaticRelaunchAfterScreenRecordingGrant()
        }
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
        if hasScreenRecordingPermission {
            clearPendingScreenRecordingFreshProcess()
        }
        // Trust System Settings: whenever the fast cached check isn't already a
        // definite "yes", ask the OS directly (via ScreenCaptureKit) whether we
        // can actually capture, and reconcile in both directions. This flips the
        // app to "granted" the moment a grant made while running takes effect —
        // even though CGPreflightScreenCaptureAccess() is still returning a stale
        // false — and flips it back to "not granted" if the grant was revoked.
        if !currentlyHasScreenRecording {
            reconcileScreenRecordingPermissionWithSystem()
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

    func refreshPermissionsAfterAppBecameActive() {
        refreshAllPermissions()
        guard UserDefaults.standard.bool(forKey: pendingScreenRecordingFreshProcessKey),
              !hasScreenRecordingPermission else { return }
        hasScheduledAutomaticScreenRecordingRelaunch = false
        scheduleAutomaticRelaunchAfterScreenRecordingGrant()
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

    private var hasScheduledAutomaticScreenRecordingRelaunch = false
    private let pendingScreenRecordingFreshProcessKey = "pendingScreenRecordingFreshProcess"
    private let pendingScreenRecordingFreshProcessAttemptsKey = "pendingScreenRecordingFreshProcessAttempts"

    private func scheduleAutomaticRelaunchAfterScreenRecordingGrant() {
        guard !hasScheduledAutomaticScreenRecordingRelaunch else { return }
        hasScheduledAutomaticScreenRecordingRelaunch = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.relaunchIfScreenRecordingGrantNeedsFreshProcess()
        }
    }

    private func relaunchIfScreenRecordingGrantNeedsFreshProcess() {
        refreshAllPermissions()
        guard NSApp.isActive else {
            hasScheduledAutomaticScreenRecordingRelaunch = false
            return
        }
        guard UserDefaults.standard.bool(forKey: pendingScreenRecordingFreshProcessKey) else { return }
        guard UserDefaults.standard.integer(forKey: pendingScreenRecordingFreshProcessAttemptsKey) < 1 else { return }
        guard !hasScreenRecordingPermission, hasAccessibilityPermission, hasMicrophonePermission else { return }

        print("🔁 Screen Recording still unavailable after grant flow; relaunching LocalClicky to refresh TCC.")
        UserDefaults.standard.set(1, forKey: pendingScreenRecordingFreshProcessAttemptsKey)
        relaunchInstalledAppAndTerminate()
    }

    private func markScreenRecordingGrantPendingFreshProcess() {
        UserDefaults.standard.set(true, forKey: pendingScreenRecordingFreshProcessKey)
        UserDefaults.standard.set(0, forKey: pendingScreenRecordingFreshProcessAttemptsKey)
    }

    private func clearPendingScreenRecordingFreshProcess() {
        UserDefaults.standard.removeObject(forKey: pendingScreenRecordingFreshProcessKey)
        UserDefaults.standard.removeObject(forKey: pendingScreenRecordingFreshProcessAttemptsKey)
    }

    private func relaunchInstalledAppAndTerminate() {
        let script = "sleep 0.5; open /Applications/LocalClicky.app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/LocalClicky.app"))
        }
        NSApp.terminate(nil)
    }

    private var isReconcilingScreenRecordingWithSystem = false
    private var lastScreenRecordingReconcileTime = Date.distantPast

    /// Asks the OS (authoritatively, via ScreenCaptureKit) whether the app can
    /// actually read the screen right now and updates `hasScreenRecordingPermission`
    /// to match — in both directions. This is what lets the app believe System
    /// Settings over the stale `CGPreflightScreenCaptureAccess()` cache: a grant
    /// made while the app is running starts working without the preflight value
    /// ever flipping to true, and a revoked grant should drop us back to "not
    /// granted" so the Grant button reappears instead of capture silently failing.
    /// Single-flight and throttled so the 1.5 s permission poll can call it freely
    /// without spawning overlapping capture queries.
    private func reconcileScreenRecordingPermissionWithSystem() {
        guard !isReconcilingScreenRecordingWithSystem else { return }
        guard Date().timeIntervalSince(lastScreenRecordingReconcileTime) > 2.5 else { return }
        isReconcilingScreenRecordingWithSystem = true
        lastScreenRecordingReconcileTime = Date()
        Task {
            let canCapture = await WindowPositionManager.canCaptureScreenContentNow()
            await MainActor.run {
                self.isReconcilingScreenRecordingWithSystem = false
                if canCapture {
                    // The OS is letting us capture → System Settings really did
                    // grant it. Believe that even if the cached preflight value
                    // still says no.
                    if !self.hasScreenRecordingPermission {
                        print("✅ Screen Recording is actually working now (System Settings grant is active); clearing the prompt.")
                    }
                    WindowPositionManager.markScreenRecordingPermissionConfirmed()
                    let wasMissingAPermission = !self.allPermissionsGranted
                    self.hasScreenRecordingPermission = true
                    self.clearPendingScreenRecordingFreshProcess()
                    // Granting screen recording may have completed the full set —
                    // reveal the cursor/intro just as the synchronous path would.
                    if wasMissingAPermission && self.allPermissionsGranted
                        && self.isClickyCursorEnabled && !self.isOverlayVisible {
                        self.presentOverlayAndIntroIfNeeded()
                    }
                } else if !WindowPositionManager.hasScreenRecordingPermission() {
                    // The OS won't let us capture AND the cached flag agrees → the
                    // grant is gone (revoked, or it was a stale saved confirmation).
                    if WindowPositionManager.hasPreviouslyConfirmedScreenRecordingPermission() {
                        WindowPositionManager.clearPreviouslyConfirmedScreenRecordingPermission()
                        print("⚠️ Screen Recording is no longer available; cleared the saved confirmation.")
                    }
                    self.hasScreenRecordingPermission = false
                }
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
                // While speaking an answer we keep showing "responding" so an idle
                // dictation state doesn't stomp it — but the instant the user
                // starts a new turn (records/finalizes/prepares), we switch to that
                // state. Without this, a turn that began while still speaking could
                // leave the UI wedged on "responding".
                let userIsInteracting = isRecording || isFinalizing || isPreparing
                // Dictation ended. At key up the recording flag falls before the
                // finalizing flag rises, so this callback sees an all-idle
                // snapshot while the transcript is still coming; discarding on
                // it would drop the capture and ink before the turn claims them.
                // The lifetime acts only if the live state is still idle after
                // the main-queue turn. A transcript is claimed synchronously as
                // the session ends, ahead of that check, so what remains is from
                // an empty or cancelled press and is dropped.
                self.pressCaptureLifetime.voiceActivityEmitted(isIdle: !userIsInteracting)
                if self.voiceState == .responding && !userIsInteracting { return }
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
            marksShownAtPress = assistantMarks.isShowing || markScheduler?.hasPending == true
            // The next press clears the assistant's marks at once, and drops
            // any still waiting for their sentence.
            cancelPendingMarks()
            marksClearTask?.cancel()
            marksClearTask = nil
            assistantMarks.clearNow()
            clearDetectedElementLocation()
            dismissSideText()
            lastResponseLatencyDescription = nil

            cancelPendingClick()
            beginTurnTimer()
            startPressCapture(timer: turnTimer)

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        self.turnTimer?.mark(.transcriptFinal)
                        print("🗣️ LocalClicky received transcript: \(finalTranscript)")
                        self.sendTranscriptToLocalModel(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            turnTimer?.mark(.keyUp)
            // End the ink now rather than on the poll's next tick, so the hold
            // and fade start at the release.
            let inkSamples = inkTrail.endStroke(finalPoint: NSEvent.mouseLocation)
            startInkPreparation(samples: inkSamples)
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Screenshot at key press

    /// Starts the capture the instant the key goes down so it overlaps the
    /// speaking time instead of adding to the wait after release. Only runs
    /// when a screen turn is possible; if it fails, the turn falls back to
    /// capturing after the transcript, as before.
    private func startPressCapture(timer: TurnTimer?) {
        discardPressCapture()
        pressCaptureLifetime.beginPress()
        guard PressCapturePolicy.shouldCapture(
            textOnlyMode: isTextOnlyMode,
            screenPermissionGranted: hasScreenRecordingPermission
        ) else { return }

        let task = Task { () -> CompanionScreenCapture? in
            guard let capture = try? await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG(),
                  !Task.isCancelled else { return nil }
            timer?.mark(.screenshotReady)
            return capture
        }
        pressCapture = PressCapture(task: task, startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    private func discardPressCapture() {
        pressCapture?.task.cancel()
        pressCapture = nil
        pendingInkTask?.cancel()
        pendingInkTask = nil
    }

    /// At key up: if the user drew something real on the display the press
    /// capture is of, start preparing it for the turn. A jiggle, a press with no
    /// capture, or a capture too old to reuse (the turn takes a fresh one, so the
    /// ink would no longer match it) means no ink goes to the model; the live
    /// trail still fades on screen.
    private func startInkPreparation(samples: [InkSample]) {
        pendingInkTask?.cancel()
        pendingInkTask = nil
        guard let press = pressCapture, !InkStroke(samples: samples).isJiggle else { return }
        let ageSeconds = Double(DispatchTime.now().uptimeNanoseconds - press.startedAtNanoseconds) / 1_000_000_000
        guard PressCapturePolicy.shouldReuse(ageSeconds: ageSeconds) else { return }

        let captureTask = press.task
        let timer = turnTimer
        pendingInkTask = Task { [weak self] in
            guard let self, let capture = await captureTask.value else { return nil }
            return await InkTurnPreparer.prepare(samples: samples, capture: capture,
                                                 trail: self.inkTrail, timer: timer)
        }
    }

    /// The screenshot for a screen turn: the key-press capture when it is
    /// there and fresh enough, else a new capture now (the old timing path).
    private func screenCaptureForTurn(
        claimed: PressCapture?,
        timer: TurnTimer?
    ) async -> CompanionScreenCapture? {
        if let claimed {
            let ageSeconds = Double(DispatchTime.now().uptimeNanoseconds - claimed.startedAtNanoseconds) / 1_000_000_000
            if PressCapturePolicy.shouldReuse(ageSeconds: ageSeconds),
               let capture = await claimed.task.value {
                timer?.setScreenshotCapturedAtPress(true)
                return capture
            }
        }
        timer?.setScreenshotCapturedAtPress(false)
        guard let capture = try? await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG() else { return nil }
        timer?.mark(.screenshotReady)
        return capture
    }

    // MARK: - Turn timing

    private func beginTurnTimer() {
        flushTurnTimer()
        turnTimer = TurnTimer()
    }

    /// Writes the record of a turn that has a transcript. A press that never
    /// produced one (empty or cancelled) is dropped without a trace.
    private func writeTurnRecord(_ timer: TurnTimer, outcome: String) {
        guard timer.hasMarked(.transcriptFinal) else { return }
        let record = timer.snapshot(outcome: outcome)
        print("⏱️ turn timing: \(record.jsonLine())")
        if !TurnTimingLog.append(record) {
            print("⚠️ could not write the turn timing log")
        }
    }

    /// Writes any record still open (a turn waiting on its cursor, or one cut
    /// off by the next press) and clears the timer.
    private func flushTurnTimer() {
        turnRecordFlushTask?.cancel()
        turnRecordFlushTask = nil
        if let timer = turnTimer {
            writeTurnRecord(timer, outcome: finishedTurnOutcome ?? "interrupted")
        }
        turnTimer = nil
        finishedTurnOutcome = nil
    }

    /// Called when a turn's response task ends. A turn that pointed keeps its
    /// record open until the cursor lands, so "cursor arrival" can be in it.
    private func finishTurnTimer(_ timer: TurnTimer, outcome: String) {
        guard turnTimer === timer else { return }
        finishedTurnOutcome = outcome
        if timer.snapshot(outcome: outcome).pointParsed && !timer.hasMarked(.cursorArrival) {
            turnRecordFlushTask?.cancel()
            turnRecordFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                self?.flushTurnTimer()
            }
            return
        }
        flushTurnTimer()
    }

    /// The overlay calls this when the blue cursor lands on the target.
    func noteCursorArrival() {
        if clickGate.noteArrival() { firePendingClick() }
        guard let timer = turnTimer, timer.hasMarked(.tagParsed) else { return }
        timer.mark(.cursorArrival)
        if finishedTurnOutcome != nil { flushTurnTimer() }
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
        cancelPendingMarks()

        let responseIdentifier = UUID()
        currentResponseIdentifier = responseIdentifier
        let timer = turnTimer
        let claimedPressCapture = pressCapture
        pressCapture = nil
        let claimedInk = pendingInkTask
        pendingInkTask = nil
        currentResponseTask = Task {
            voiceState = .processing
            var turnOutcome = "completed"
            defer {
                // Marks the turn drew clear 1.5 s after the speech ends.
                if !Task.isCancelled { scheduleMarksClearAfterSpeech() }
                if let timer { finishTurnTimer(timer, outcome: Task.isCancelled ? "interrupted" : turnOutcome) }
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
                //
                // Ink first: a stroke the user drew while holding the keys makes
                // this a screen turn whatever the words say (see InkRouting). The
                // package was started at key up, so this usually returns at once.
                let inkPackage = await claimedInk?.value
                let route = DrawingRouting.route(
                    transcript: transcript,
                    context: ConversationRouter.Context(
                        visionModeSelected: !isTextOnlyMode,
                        screenAvailable: hasScreenRecordingPermission,
                        previousTurnUsedScreen: previousTurnUsedScreen,
                        hasConversationHistory: !conversationHistory.isEmpty,
                        previousTurnWasPointing: previousTurnWasPointing
                    ),
                    hasUsableInk: inkPackage != nil,
                    drawingEnabled: drawingEnabled
                )
                previousTurnWasPointing = (route == .screenPoint || route == .screenClick)
                let drawnAtPress = marksShownAtPress
                marksShownAtPress = false

                timer?.setRoute(String(describing: route))

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
                if route == .setTimer {
                    await handleSetTimer(transcript: transcript)
                    settleAfterAction()
                    return
                }
                if route == .spotify {
                    await handleSpotifyCommand(transcript: transcript)
                    settleAfterAction()
                    return
                }
                if route == .clearMarks {
                    await handleClearMarks(transcript: transcript, drawnAtPress: drawnAtPress)
                    settleAfterAction()
                    return
                }

                // A click turn grounds the element exactly like a pointing turn
                // (same grounding model + tag); it just also clicks at the end.
                let performClick = (route == .screenClick)
                let wantsDrawing = (route == .screenDraw)
                // A sketch marks nothing: a template figure is composed by the app, a
                // freeform one is drawn by the grounding model (see Sketch.swift).
                let wantsSketch = (route == .screenSketch)
                let useScreen = (route == .screen || route == .screenPoint || route == .screenClick || wantsDrawing || wantsSketch)
                let wantsPointing = (route == .screenPoint || route == .screenClick)
                // A drawing turn grounds like a pointing turn: the model's
                // coordinates are in the full image, so no close-up, a tight
                // prompt and no clock context.
                let wantsGrounding = wantsPointing || wantsDrawing
                // A pointing turn with no object of its own ("point out to me again") gets the last one put into
                // the words the model sees. History stays off for it, so a refusal is never restored.
                let followUp = wantsPointing ? PointingFollowUp.resolve(transcript: transcript, lastObject: lastPointingObject) : nil
                if let followUp { lastPointingObject = followUp.object }
                let groundingTranscript = followUp?.transcript ?? transcript
                // A circle or arrow request is drawn from a point: the grounding
                // model gets the pointing prompt and the app builds the mark
                // (PointThenDraw). Other marks, and the flag off, keep the shape tags.
                var pointThenDrawKind: PointDrawKind? = wantsDrawing
                    ? DrawingIntent.pointThenDrawKind(transcript, pointThenDrawEnabled: PointThenDraw.isEnabled())
                    : nil

                var cursorScreenCapture: CompanionScreenCapture?
                let systemPrompt: String
                var userImagesBase64: [String] = []
                let model: String

                if !useScreen { claimedPressCapture?.task.cancel() }
                // With ink, the turn's screenshot is the press-time capture with
                // the stroke composited into it (same size and mapping).
                let usableInk = (useScreen && !wantsSketch) ? inkPackage : nil
                // A describe turn with ink is naming (the eval's A1FPC request: the
                // ink system prompt and mark line, no Accessibility block, no
                // history) or explain (every other question about the marked area).
                // Grounding turns keep theirs. See InkTurnPolicy.
                let inkPlan = InkTurnPolicy.plan(transcript: transcript, hasUsableInk: usableInk != nil,
                                                 wantsGrounding: wantsGrounding)
                if let inkPlan { timer?.setRoute(String(describing: route) + "+ink-\(inkPlan.kind)") }
                let screenCapture: CompanionScreenCapture?
                if let usableInk {
                    timer?.setScreenshotCapturedAtPress(true)
                    screenCapture = usableInk.capture
                } else if useScreen {
                    screenCapture = await screenCaptureForTurn(claimed: claimedPressCapture, timer: timer)
                } else {
                    screenCapture = nil
                }
                var inkCloseUpAttached = false
                if let capture = screenCapture {
                    cursorScreenCapture = capture
                    // A figure with a template is drawn and spoken by the app, with no model call.
                    if wantsSketch, let plan = sketchPlan(for: transcript, in: capture) {
                        await showSketch(plan, transcript: transcript, route: route, in: capture, timer: timer)
                        settleAfterAction()
                        return
                    }
                    userImagesBase64 = [capture.imageData.base64EncodedString()]
                    // Describe turns also get the close-up. Pointing, clicking and
                    // drawing turns must not: their coordinates refer to the full image.
                    if let usableInk, !wantsGrounding, let closeUp = usableInk.cropImageData {
                        userImagesBase64.append(closeUp.base64EncodedString())
                        inkCloseUpAttached = true
                    }
                    if let usableInk {
                        timer?.setInk(marks: usableInk.markCount, crop: inkCloseUpAttached)
                    }
                    if wantsPointing {
                        // Pointing turn: use the grounding model + the pointing
                        // prompt. If the resolved model can't ground (grounding
                        // model not installed and the vision model is Moondream),
                        // describe instead of asking it for empty coordinates.
                        let pointingModel = resolvedGroundingModelName()
                        if LocalModels.isLikelyGroundingCapable(pointingModel) {
                            systemPrompt = performClick
                                ? LocalPrompts.screenClickResponse(
                                    imageWidthInPixels: capture.screenshotWidthInPixels,
                                    imageHeightInPixels: capture.screenshotHeightInPixels)
                                : LocalPrompts.screenPointResponse(
                                    imageWidthInPixels: capture.screenshotWidthInPixels,
                                    imageHeightInPixels: capture.screenshotHeightInPixels)
                        } else {
                            systemPrompt = LocalPrompts.screenDescribe(
                                imageWidthInPixels: capture.screenshotWidthInPixels,
                                imageHeightInPixels: capture.screenshotHeightInPixels)
                        }
                        model = pointingModel
                    } else if wantsSketch {
                        // Freeform sketch (sketchPlan returned nil, so the grounding
                        // model can draw): its own prompt, in the gateway's 0 to 1000 frame.
                        systemPrompt = LocalPrompts.screenSketchResponse
                        model = resolvedGroundingModelName()
                    } else if wantsDrawing {
                        // Drawing turn: the grounding model with the shape
                        // prompt. If the resolved model cannot ground, describe
                        // instead, the same fallback a pointing turn has.
                        let drawingModel = resolvedGroundingModelName()
                        if LocalModels.isLikelyGroundingCapable(drawingModel) {
                            systemPrompt = pointThenDrawKind != nil
                                ? LocalPrompts.screenPointResponse(
                                    imageWidthInPixels: capture.screenshotWidthInPixels,
                                    imageHeightInPixels: capture.screenshotHeightInPixels)
                                : LocalPrompts.screenDrawResponse(
                                    imageWidthInPixels: capture.screenshotWidthInPixels,
                                    imageHeightInPixels: capture.screenshotHeightInPixels)
                        } else {
                            pointThenDrawKind = nil
                            systemPrompt = LocalPrompts.screenDescribe(
                                imageWidthInPixels: capture.screenshotWidthInPixels,
                                imageHeightInPixels: capture.screenshotHeightInPixels)
                        }
                        model = drawingModel
                    } else {
                        // Describe/answer turn: the default vision model (Moondream),
                        // which is strong at description but doesn't emit coordinates.
                        switch inkPlan?.kind {
                        case .naming: systemPrompt = LocalPrompts.inkDescribe
                        case .explain: systemPrompt = LocalPrompts.inkExplain
                        case nil:
                            systemPrompt = LocalPrompts.screenDescribe(
                                imageWidthInPixels: capture.screenshotWidthInPixels,
                                imageHeightInPixels: capture.screenshotHeightInPixels)
                        }
                        model = visionModelName
                    }
                } else {
                    systemPrompt = LocalPrompts.textVoiceResponse
                    model = chatModelName
                }

                guard !Task.isCancelled else { return }

                timer?.setModel(model)
                if let capture = cursorScreenCapture {
                    timer?.setImageSize(width: capture.screenshotWidthInPixels,
                                        height: capture.screenshotHeightInPixels)
                }

                // Give conversational turns awareness of the real-world clock so
                // "what time is it / what's today's date / what day is it" work —
                // the model has no clock of its own. Pointing/click turns get the
                // tight grounding prompt untouched (time is irrelevant + would only
                // distract the tag output).
                let systemWithContext = wantsGrounding || wantsSketch || inkPlan != nil
                    ? systemPrompt
                    : systemPrompt + "\n\n" + Self.currentEnvironmentContext()

                var messages: [OllamaChatMessage] = [.system(systemWithContext)]
                // A grounding turn sends no history: the measured pointing request
                // has none, and after one "i don't see it" every retry was primed
                // to say it again. A naming turn sends none either, so it is the
                // measured request on every turn of a session.
                if InkTurnPolicy.sendsHistory(wantsGrounding: wantsGrounding || wantsSketch, plan: inkPlan) {
                    for exchange in conversationHistory {
                        messages.append(.user(exchange.userTranscript))
                        messages.append(.assistant(exchange.assistantResponse))
                    }
                }
                // The ink text rides after the user's words, so every system
                // prompt but the ink describe turn's stays as it is with no ink.
                var userText = groundingTranscript
                // A window or app is not the control the point prompt talks about. A
                // point-then-draw turn sends the point prompt too, so it gets the line.
                let windowLine = PointingTarget.wantsWindowLine(transcript: groundingTranscript, wantsPointing: wantsPointing,
                                                                pointDrawKind: pointThenDrawKind)
                if windowLine {
                    userText += "\n\n" + LocalPrompts.windowTargetLine
                }
                let pointingInfo = PointingTurnInfo(transcript: transcript, substitutedObject: followUp?.substitutedObject,
                                                    object: followUp?.substitutedObject ?? PointingFollowUp.object(in: transcript),
                                                    namesWindow: wantsPointing && windowLine)
                if let usableInk {
                    userText += "\n\n" + LocalPrompts.inkAddendum(
                        gestureSummary: usableInk.gestureSummary,
                        markerColourName: usableInk.markerColourName,
                        hasCloseUp: inkCloseUpAttached,
                        accessibilityBlock: (inkPlan?.sendsAccessibilityBlock ?? true) ? usableInk.accessibilityBlock : "",
                        markKind: inkPlan != nil ? usableInk.markKind : nil)
                }
                messages.append(.user(userText, imagesBase64: userImagesBase64))

                // Stream the answer and speak it sentence-by-sentence as it
                // arrives, so the companion starts talking before the whole
                // answer finishes generating. A single serial consumer task
                // speaks each ready sentence in order; the pointing tag is never
                // spoken (speakablePrefix stops at it).
                let (sentenceStream, sentenceContinuation) = AsyncStream<(clipID: Int?, text: String)>.makeStream()
                let speechProgress = StreamingSpeechProgress()
                defer { sentenceContinuation.finish() }

                let speakingTask = Task { @MainActor [weak self] in
                    for await sentence in sentenceStream {
                        if Task.isCancelled { break }
                        guard let self else { break }
                        do {
                            try await self.speechSynthesizer.speakText(sentence.text, clipID: sentence.clipID)
                            timer?.mark(.firstAudio)
                        }
                        catch is CancellationError { break }
                        catch { print("⚠️ TTS error: \(error)") }
                    }
                }

                // Pointing/click turns want just a sentence + tag; describe and
                // text turns get enough room to finish a real thought (the prompt
                // still asks for brevity) so answers don't get truncated mid-word.
                let answerMaxTokens: Int = {
                    if wantsPointing || pointThenDrawKind != nil { return 130 }
                    // Up to three tag-first beat lines: tags are token-heavy.
                    if wantsDrawing { return 260 }
                    // Up to SketchLimits.maxTags tags and one sentence.
                    if wantsSketch { return SketchLimits.freeformAnswerMaxTokens }
                    if cursorScreenCapture == nil { return 420 }
                    return 320
                }()
                // Fly the cursor as soon as the tag's closing bracket streams in,
                // rather than after the stream ends. The final parse below still
                // decides: if it disagrees, the final point wins.
                // A point-then-draw turn draws the mark, so the blue cursor stays put.
                let drawFromPointKind = pointThenDrawKind
                let pointingCapture = (drawFromPointKind == nil && !wantsSketch) ? cursorScreenCapture : nil
                let pointDetector = StreamingPointDetector()
                let pointingState = TurnPointingState()
                // Ink out: each closed SHAPE or HIGHLIGHT tag is shown the moment
                // it closes. Only a drawing turn reads them.
                let drawingCapture = (wantsDrawing || wantsSketch) ? cursorScreenCapture : nil
                let shapeDetector = StreamingShapeDetector()
                // Marks wait for their sentence to be spoken: a tag binds to the
                // next sentence queued after it, and shows when that clip starts.
                let scheduler: SpeechMarkSchedulerBox<InkDrawing>? = drawingCapture == nil ? nil : {
                    let box = SpeechMarkSchedulerBox<InkDrawing>(firstClipID: nextClipIDBase)
                    nextClipIDBase += 100_000
                    return box
                }()
                defer { scheduler?.finishInput() }
                if let scheduler, let capture = drawingCapture {
                    startMarkDriver(scheduler, in: capture, timer: timer)
                    if wantsSketch { marksHoldSeconds = SketchTiming.holdSeconds }
                }

                timer?.mark(.requestSent)
                let result = try await ollamaClient.streamChat(
                    model: model,
                    messages: messages,
                    temperature: cursorScreenCapture == nil ? 0.7 : 0.3,
                    maxTokens: answerMaxTokens,
                    keepAlive: hardwareRecommendation.keepAlive,
                    contextWindow: contextWindow(forModel: model),
                    turn: inkPlan?.turnHeader,
                    onText: { accumulated in
                        timer?.mark(.firstToken)
                        // Tags first, then sentences: a tag-first beat line
                        // delivered in one chunk must close its mark before its
                        // sentence is queued, so the mark binds to that sentence.
                        if let scheduler, drawFromPointKind == nil {
                            for drawing in shapeDetector.feed(accumulated: accumulated)
                            where !wantsSketch || SketchLimits.admits(drawing, alreadyClosed: scheduler.closedCount) {
                                scheduler.markClosed(drawing)
                            }
                        }
                        // A point-then-draw turn speaks its own sentence once the
                        // mark is built, not the pointing prompt's "click the...".
                        // A sketch speaks at the end, once it is known to hold a tag.
                        if drawFromPointKind == nil, !wantsSketch {
                            let speakable = SpokenTextSegmenter.speakablePrefix(accumulated)
                            if let (sentence, _) = speechProgress.advance(speakable: speakable) {
                                sentenceContinuation.yield((clipID: scheduler?.sentenceQueued(), text: sentence))
                            }
                        }
                        if let capture = pointingCapture,
                           let tag = pointDetector.feed(accumulated: accumulated),
                           let center = tag.centerInImagePixels {
                            Task { @MainActor [weak self] in
                                guard let self,
                                      !pointingState.isFinalized,
                                      self.currentResponseIdentifier == responseIdentifier else { return }
                                // The tag is parsed now, so the timing is marked before the snap. The reconcile below
                                // compares the model's own points, so it gets `center`.
                                pointingState.earlyDispatchedImagePoint = center
                                timer?.mark(.tagParsed)
                                timer?.setPointParsed(true)
                                // Snapped to the window or control the model named (at most about 150 ms).
                                let snap = Task { @MainActor in
                                    await self.snappedImagePoint(center, label: tag.label, info: pointingInfo, in: capture)
                                }
                                pointingState.earlySnap = snap
                                let target = await snap.value
                                guard !pointingState.isFinalized,
                                      self.currentResponseIdentifier == responseIdentifier else { return }
                                pointingState.earlyDispatchedLocation = self.dispatchPointerFlight(toImagePoint: target, label: tag.label, in: capture)
                            }
                        }
                    }
                )
                pointingState.isFinalized = true

                // Circle or arrow request: build the mark from the point reply. The
                // mark closes before its sentence is queued, so it binds to it and
                // shows when that sentence starts. With no point ([POINT:none]) the
                // model's own sentence is spoken and nothing is drawn.
                var drawnFromPointSentence: String?
                if let kind = drawFromPointKind, let scheduler, let capture = cursorScreenCapture, !Task.isCancelled {
                    let reply = PointingTagParser.parse(from: result.text)
                    if let centre = reply.centerInImagePixels {
                        let plan = PointThenDraw.plan(
                            kind: kind,
                            pointInImagePixels: centre,
                            label: reply.label,
                            controlFrameInDisplayPoints: await controlFrameInDisplayPoints(atImagePoint: centre, in: capture),
                            mapping: screenMapping(for: capture))
                        scheduler.markClosed(plan.drawing)
                        drawnFromPointSentence = plan.spokenSentence
                    }
                }

                // A tag that closed in the very last chunk. The detector never
                // returns a tag twice, so this only adds what the stream missed.
                if let scheduler, !Task.isCancelled {
                    for drawing in drawFromPointKind == nil ? shapeDetector.feed(accumulated: result.text) : []
                    where !wantsSketch || SketchLimits.admits(drawing, alreadyClosed: scheduler.closedCount) {
                        scheduler.markClosed(drawing)
                    }
                    scheduler.finishInput()
                    timer?.setMarks(scheduler.closedCount)
                    // A sketch speaks its own words once, or says it drew nothing or has no sentence
                    // (SketchLimits.spokenSentence); it is spoken as one sentence at the end.
                    if wantsSketch {
                        drawnFromPointSentence = SketchLimits.spokenSentence(in: result.text, closedTags: scheduler.closedCount)
                    }
                }

                guard !Task.isCancelled else {
                    sentenceContinuation.finish()
                    speakingTask.cancel()
                    return
                }

                let pointing = PointingTagParser.parse(from: result.text)
                // A drawing turn's words carry SHAPE and HIGHLIGHT tags too; none goes into the history.
                let spokenText = drawnFromPointSentence
                    ?? (drawingCapture != nil ? ShapeTagParser.parse(from: result.text).spokenText : pointing.spokenText)
                if pointing.hasPoint {
                    timer?.mark(.tagParsed)
                    timer?.setPointParsed(true)
                }

                // Flush the final sentence (no trailing space, so not emitted
                // during streaming), then close the stream so the speaker drains.
                let remainder = speechProgress.remainder(
                    speakable: SpokenTextSegmenter.speakablePrefix(result.text))
                if let drawnFromPointSentence {
                    sentenceContinuation.yield((clipID: scheduler?.sentenceQueued(), text: drawnFromPointSentence))
                } else if !remainder.isEmpty {
                    sentenceContinuation.yield((clipID: scheduler?.sentenceQueued(), text: remainder))
                }
                sentenceContinuation.finish()

                if drawFromPointKind == nil, !wantsSketch, let capture = cursorScreenCapture {
                    var clickLocation: CGPoint?
                    switch PointReconciliation.reconcile(
                        early: pointingState.earlyDispatchedImagePoint,
                        final: pointing.centerInImagePixels
                    ) {
                    case .nothing:
                        break
                    case .keepEarly:
                        // The early flight went to the snapped point; a click goes there too.
                        if let early = pointingState.earlyDispatchedLocation {
                            clickLocation = early
                        } else if let snap = pointingState.earlySnap {
                            // The stream ended while the early point was being snapped: use that snap.
                            let target = await snap.value
                            clickLocation = dispatchPointerFlight(toImagePoint: target, label: pointing.label, in: capture)
                        } else if let center = pointing.centerInImagePixels {
                            clickLocation = globalScreenLocation(forImagePoint: center, in: capture)
                        }
                    case .dispatchFinal(let center):
                        let target = await snappedImagePoint(center, label: pointing.label, info: pointingInfo, in: capture)
                        clickLocation = dispatchPointerFlight(toImagePoint: target, label: pointing.label, in: capture)
                    case .earlyWithdrawn:
                        print("⚠️ The final parse has no point but the cursor already left early; not clicking.")
                    }
                    // On a click turn, let the blue cursor visibly fly to the
                    // target first, then perform a real click there so the user
                    // sees exactly what's about to be clicked.
                    if performClick, let clickLocation {
                        scheduleRealClick(atGlobalAppKitPoint: clickLocation)
                    }
                }

                // A sketch records a neutral note, not its sentence, so a later chat turn has nothing to recite
                // for a drawing that is gone (or never was). lastSpokenAnswer below keeps the real sentence.
                let historyText = wantsSketch
                    ? SketchHistory.note(for: SketchIntent.figure(transcript) ?? .freeform("something"),
                                         drew: (scheduler?.closedCount ?? 0) > 0)
                    : spokenText
                conversationHistory.append((userTranscript: transcript, assistantResponse: historyText))
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
                // Let the first mark reach the screen before the turn record is
                // written, so first_mark is the real display time. Bounded: a
                // mark is never held longer than SpeechMarkTiming.startTimeout.
                if let scheduler {
                    let give = Date().addingTimeInterval(SpeechMarkTiming.startTimeout + 0.5)
                    while scheduler.releasedCount == 0, scheduler.hasPending, !Task.isCancelled, Date() < give {
                        try? await Task.sleep(nanoseconds: 25_000_000)
                    }
                }
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
                turnOutcome = "error"
                print("⚠️ Local model error: \(error.localizedDescription)")
                refreshLocalEngineStatus()
                speakErrorFallback(reason: error.speakableReason)
            } catch {
                turnOutcome = "error"
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

    /// What the app draws for a sketch turn, or nil when the grounding model should draw it
    /// (a figure with no template, with SketchLimits.freeformEnabled on and a grounding model
    /// available). With that path off the plan is the spoken list of what the app can draw.
    /// A template is placed where the words said and sized as they said (SketchRequest).
    private func sketchPlan(for transcript: String, in capture: CompanionScreenCapture) -> SketchPlan? {
        let request = SketchIntent.parse(transcript)
        if let request, let plan = SketchTemplate.plan(request.figure, imageWidth: capture.screenshotWidthInPixels,
                                                       imageHeight: capture.screenshotHeightInPixels,
                                                       anchor: request.anchor, size: request.size, board: request.board) {
            return plan
        }
        if SketchLimits.freeformEnabled, LocalModels.isLikelyGroundingCapable(resolvedGroundingModelName()) { return nil }
        return SketchPlan(drawings: [], spokenSentence: SketchTemplate.unsupportedSentence)
    }

    /// Draws a template sketch and speaks its one sentence. Every mark closes before the
    /// sentence is queued, so all of them show when that clip starts (SpeechMarkScheduler);
    /// the figure then holds SketchTiming.holdSeconds after the speech.
    private func showSketch(_ plan: SketchPlan, transcript: String, route: ConversationRoute,
                            in capture: CompanionScreenCapture, timer: TurnTimer?) async {
        let scheduler = SpeechMarkSchedulerBox<InkDrawing>(firstClipID: nextClipIDBase)
        nextClipIDBase += 100_000
        startMarkDriver(scheduler, in: capture, timer: timer)
        marksHoldSeconds = SketchTiming.holdSeconds
        for drawing in plan.drawings { scheduler.markClosed(drawing) }
        let clipID = scheduler.sentenceQueued()
        scheduler.finishInput()
        timer?.setMarks(scheduler.closedCount)

        // The history holds a neutral note, not the sentence: a later chat turn recites a sentence it finds there
        // for a drawing that is gone. lastSpokenAnswer keeps the real sentence for "copy your answer".
        let request = SketchIntent.parse(transcript)
        let note = plan.drawings.isEmpty ? "(could not draw that)" : SketchHistory.note(for: request?.figure ?? .freeform("something"))
        conversationHistory.append((userTranscript: transcript, assistantResponse: note))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        lastSpokenAnswer = plan.spokenSentence
        previousTurnUsedScreen = true

        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("sketch", ["transcript": transcript, "route": String(describing: route),
                                          "figure": request.map { String(describing: $0.figure) } ?? "none",
                                          "anchor": request?.anchor.name ?? "none",
                                          "size": request.map { String(describing: $0.size) } ?? "none",
                                          "board": request?.board ?? "", "spoken": plan.spokenSentence])

        voiceState = .responding
        do { try await speechSynthesizer.speakText(plan.spokenSentence, clipID: clipID) }
        catch { print("⚠️ TTS error during sketch: \(error)") }
    }

    /// "clear that": takes down what the assistant drew and says so. A key press already
    /// clears the marks, so this is the spoken confirmation of that. `drawnAtPress` says
    /// there were marks when the key went down. With nothing drawn (the sketch's 10 s hold
    /// already ended) it says so, and the turn does not fall through to chat.
    private func handleClearMarks(transcript: String, drawnAtPress: Bool) async {
        let cleared = drawnAtPress || assistantMarks.isShowing || markScheduler?.hasPending == true
        marksClearTask?.cancel()
        marksClearTask = nil
        cancelPendingMarks()
        assistantMarks.clearNow()
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("clear", ["transcript": transcript, "cleared": cleared])
        voiceState = .responding
        do { try await speechSynthesizer.speakText(cleared ? "cleared." : "nothing is drawn right now.") }
        catch { print("⚠️ TTS error during clear: \(error)") }
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
        // The user explicitly asked for the answer *in text*, so this turn is
        // text-only: render it in the blue side-text and do NOT speak it. (Every
        // other route is voice-first; this is the one the user opts into for a
        // silent, readable answer.)
        streamSideText(answer, characterInterval: 0.02, holdSeconds: 12, autoDismiss: true)
        voiceState = .idle
    }

    // MARK: - Web reach (the one opt-in internet feature)

    /// Answers an internet-needing question: fetches web results via WebReachTool
    /// (Jina Reader — the one documented cloud call), then has the local text
    /// model synthesize a spoken answer grounded only in what was fetched. Shows
    /// "checking the web…" in the blue text first, since this is the single
    /// feature that leaves the no-cloud guarantee.
    private func handleWebReachCommand(transcript: String) async {
        voiceState = .processing

        // Weather goes to a dedicated, accurate source (general search results
        // don't carry live conditions).
        if WebReachTool.isWeatherQuery(transcript) {
            streamSideText("checking the weather…", autoDismiss: false)
            if let report = await WebReachTool.weatherReport(forQuery: transcript) {
                guard !Task.isCancelled else { dismissSideText(); return }
                await synthesizeAndSpeakWebAnswer(transcript: transcript, results: report)
                return
            }
            // Fall through to a normal web search if the weather source failed.
        }

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

        await synthesizeAndSpeakWebAnswer(transcript: transcript, results: results)
    }

    /// Has the local text model synthesize a spoken answer grounded only in the
    /// fetched web/weather results, then speaks it. Shared by the weather and the
    /// general-search paths.
    private func synthesizeAndSpeakWebAnswer(transcript: String, results: String) async {
        var answer = ""
        do {
            let synthesis = try await ollamaClient.streamChat(
                model: chatModelName,
                messages: [.system(LocalPrompts.webAnswer),
                           .user("question: \(transcript)\n\nfetched web content (source of truth):\n\(results)")],
                temperature: 0.0,
                maxTokens: 200,
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

    // MARK: - Computer use (timer + Spotify)

    /// Starts an in-app countdown timer and confirms it out loud. The timer
    /// announces itself when it finishes (see `timerService.onTimerFinished`).
    private func handleSetTimer(transcript: String) async {
        previousTurnUsedScreen = false
        guard let request = ComputerActionPlanner.timerRequest(from: transcript) else {
            let message = "tell me how long, like set a timer for five minutes."
            voiceState = .responding
            do { try await speechSynthesizer.speakText(message) } catch {}
            return
        }
        timerService.startTimer(seconds: request.seconds, spokenDuration: request.spokenDuration)
        print("⏲️ Timer: set for \(request.seconds)s (\(request.spokenDuration))")
        let message = "okay, timer set for \(request.spokenDuration). i'll let you know when it's done."
        conversationHistory.append((userTranscript: transcript, assistantResponse: message))
        voiceState = .responding
        do { try await speechSynthesizer.speakText(message) }
        catch { print("⚠️ TTS error during timer: \(error)") }
    }

    /// Controls the Spotify desktop app for an explicit "… on spotify" command.
    private func handleSpotifyCommand(transcript: String) async {
        previousTurnUsedScreen = false
        guard let action = ComputerActionPlanner.spotifyAction(from: transcript) else { return }

        let outcome = SpotifyController.perform(action)
        let message: String
        switch outcome {
        case .notInstalled:
            message = "i don't see spotify installed on your mac."
        case .permissionDenied:
            message = "i need permission to control spotify — allow it under privacy and security, automation."
        case .failed:
            message = "i couldn't get spotify to do that just now."
        case .ok:
            switch action {
            case .play: message = "playing on spotify."
            case .pause: message = "paused spotify."
            case .next: message = "skipping to the next track."
            case .previous: message = "going back a track."
            case .playQuery(let query): message = "pulling up \(query) on spotify."
            }
        }
        print("🎵 Spotify: \(action) → \(outcome)")
        conversationHistory.append((userTranscript: transcript, assistantResponse: message))
        voiceState = .responding
        do { try await speechSynthesizer.speakText(message) }
        catch { print("⚠️ TTS error during spotify: \(error)") }
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

    /// Shows each mark when its sentence is being spoken. The scheduler decides
    /// when a mark is due (SpeechMarkScheduler); this task polls it every 25 ms
    /// and hands due marks to the overlay, and ends when nothing is waiting and
    /// the stream is done, or at a barge-in (`cancelPendingMarks`).
    private func startMarkDriver(_ scheduler: SpeechMarkSchedulerBox<InkDrawing>,
                                 in capture: CompanionScreenCapture,
                                 timer: TurnTimer?) {
        cancelPendingMarks()
        markScheduler = scheduler
        speechSynthesizer.onClipStart = { [weak scheduler] start in
            scheduler?.clipStarted(id: start.id, audibleIn: start.audibleIn)
        }
        markDriverTask = Task { [weak self] in
            while !Task.isCancelled {
                let due = scheduler.release()
                if !due.isEmpty { self?.showMarks(due, in: capture, timer: timer) }
                if scheduler.isDone { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    /// Barge-in or a new press: marks still waiting for their sentence are
    /// dropped and never shown.
    private func cancelPendingMarks() {
        marksHoldSeconds = nil
        markDriverTask?.cancel()
        markDriverTask = nil
        markScheduler?.cancel()
        markScheduler = nil
        speechSynthesizer.onClipStart = nil
    }

    private func screenMapping(for capture: CompanionScreenCapture) -> ScreenMapping {
        ScreenMapping(displayFrame: capture.displayFrame,
                      displayWidthInPoints: capture.displayWidthInPoints,
                      displayHeightInPoints: capture.displayHeightInPoints,
                      screenshotWidthInPixels: capture.screenshotWidthInPixels,
                      screenshotHeightInPixels: capture.screenshotHeightInPixels)
    }

    /// The Accessibility frame of the control under a point of the screenshot, in
    /// display-local points, or nil when there is none (no permission, no answer
    /// within the harvester's budget, no frame). PointThenDraw sizes the ring from it.
    private func controlFrameInDisplayPoints(atImagePoint point: CGPoint, in capture: CompanionScreenCapture) async -> CGRect? {
        let mapping = screenMapping(for: capture)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let cgPoint = mapping.cgGlobalPoint(forDisplayLocalPoint: mapping.displayLocalPoint(forImagePoint: point),
                                            primaryScreenHeight: primaryHeight)
        guard let frame = await AccessibilityHarvester.frameOfElement(atCGPoint: cgPoint) else { return nil }
        return mapping.displayLocalRect(forCGGlobalRect: frame, primaryScreenHeight: primaryHeight)
    }

    /// Hands marks to the overlay of the display the screenshot was taken of.
    /// first_mark is recorded here, at the moment of display.
    private func showMarks(_ drawings: [InkDrawing], in capture: CompanionScreenCapture, timer: TurnTimer?) {
        let mapping = ScreenMapping(displayFrame: capture.displayFrame,
                                    displayWidthInPoints: capture.displayWidthInPoints,
                                    displayHeightInPoints: capture.displayHeightInPoints,
                                    screenshotWidthInPixels: capture.screenshotWidthInPixels,
                                    screenshotHeightInPixels: capture.screenshotHeightInPixels)
        let reduceMotion = InkDisplayOptions.current().reduceMotion
        for drawing in drawings {
            let geometry = MarkGeometryBuilder.geometry(for: MarkGeometryBuilder.overlayDrawing(from: drawing, mapping: mapping))
            guard geometry.passes.contains(where: { !$0.isEmpty }) else { continue }
            timer?.mark(.firstMark)
            assistantMarks.add(geometry: geometry, displayFrame: capture.displayFrame, reduceMotion: reduceMotion)
        }
    }

    /// Waits for the speech to finish, then starts the marks' hold and fade.
    /// A new key press cancels it and clears the marks at once.
    private func scheduleMarksClearAfterSpeech() {
        guard assistantMarks.isShowing || markScheduler?.hasPending == true else { return }
        marksClearTask?.cancel()
        marksClearTask = Task { [weak self] in
            // Marks still waiting for their sentence count: they show, then fade.
            while let self, self.speechSynthesizer.isPlaying || self.markScheduler?.hasPending == true {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            let fade = self.inkTrail.style.fade
            let hold = self.marksHoldSeconds ?? fade.hold
            self.marksHoldSeconds = nil
            self.assistantMarks.scheduleClear(hold: hold, fade: fade.fade)
        }
    }

    /// The model's point moved onto the window (a window request) or the control (anything else) it named, in
    /// screenshot pixels; the model's own point when nothing matches (PointSnap, PointSnapper). Waits at most
    /// about PointSnap.budgetSeconds.
    private func snappedImagePoint(_ point: CGPoint, label: String?, info: PointingTurnInfo,
                                   in capture: CompanionScreenCapture) async -> CGPoint {
        // Read here, on the main actor; the snap itself runs off it.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let outcome = await PointSnapper.snap(imagePoint: point, label: label, object: info.object, namesWindow: info.namesWindow,
                                              mapping: screenMapping(for: capture), primaryHeight: primaryHeight)
        print("📍 Snap: \(outcome.result.kind.rawValue) (\(Int(point.x)), \(Int(point.y))) px → (\(Int(outcome.imagePoint.x)), \(Int(outcome.imagePoint.y))) px")
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("point", ["transcript": info.transcript,
                                         "substitutedObject": info.substitutedObject ?? NSNull(),
                                         "windowLine": info.namesWindow,
                                         "modelPointPx": TempAppDebugLog.point(point),
                                         "label": label ?? NSNull(),
                                         "snap": outcome.result.kind.rawValue,
                                         "snappedScreenPoint": outcome.snappedScreenPoint.map { TempAppDebugLog.point($0) } ?? NSNull(),
                                         "matchedLabel": outcome.result.matchedLabel ?? NSNull()])
        return outcome.imagePoint
    }

    /// Sends the blue cursor to a point in the screenshot's pixel space and
    /// returns the global AppKit location it maps to. Switches to idle BEFORE
    /// setting the location so the triangle is visible and can fly to the target.
    @discardableResult
    private func dispatchPointerFlight(
        toImagePoint center: CGPoint,
        label: String?,
        in capture: CompanionScreenCapture
    ) -> CGPoint {
        voiceState = .idle
        clickGate.targetChanged()
        let globalLocation = globalScreenLocation(forImagePoint: center, in: capture)
        // The bubble reads this when the cursor lands, so set it before the
        // location. A label that is missing or too long leaves it nil and the
        // overlay keeps its random phrase.
        detectedElementBubbleText = PointingLabel.bubbleText(from: label)
        detectedElementScreenLocation = globalLocation
        detectedElementDisplayFrame = capture.displayFrame
        print("🎯 Pointing at \"\(label ?? "element")\" → (\(Int(center.x)), \(Int(center.y))) px")
        return globalLocation
    }

    /// A short present-tense line describing the real-world context (current
    /// date, weekday, and local time) appended to conversational system prompts so
    /// the model can answer "what time is it / what's today's date / what day is
    /// it" — it has no clock of its own and otherwise guesses or refuses.
    static func currentEnvironmentContext() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let stamp = formatter.string(from: Date())
        return "for reference, the user's current local date and time is \(stamp). if they ask what time/day/date it is, answer from this naturally and spoken-style; otherwise ignore it."
    }

    /// Performs a real click at the grounded element once the blue cursor has
    /// visibly landed there, so the click is clearly telegraphed. Only ever
    /// called on an explicit click turn (route `.screenClick`) and only after
    /// the final parse confirmed the point. A click is the only action it can
    /// take. If the overlay never reports arrival, a fallback fires it after
    /// `ClickGate.fallbackTimeoutSeconds`. Pressing the key again cancels it.
    private func scheduleRealClick(atGlobalAppKitPoint appKitPoint: CGPoint) {
        pendingClickCGPoint = ClickActionExecutor.cgGlobalPoint(fromAppKitGlobalPoint: appKitPoint)
        if clickGate.requestClick() {
            firePendingClick()
            return
        }
        clickFallbackTask?.cancel()
        clickFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ClickGate.fallbackTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.clickGate.noteTimeout() { self.firePendingClick() }
        }
    }

    private func firePendingClick() {
        clickFallbackTask?.cancel()
        clickFallbackTask = nil
        guard let cgPoint = pendingClickCGPoint else { return }
        pendingClickCGPoint = nil
        print("🖱️ Click: at CG (\(Int(cgPoint.x)), \(Int(cgPoint.y)))")
        ClickActionExecutor.click(atCGGlobalPoint: cgPoint)
    }

    /// Drops a click that has not fired yet and starts a fresh gate for the
    /// next turn (a new key press interrupts the old turn).
    private func cancelPendingClick() {
        clickFallbackTask?.cancel()
        clickFallbackTask = nil
        pendingClickCGPoint = nil
        clickGate.reset()
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
            // Keep the overlay until the assistant's marks have faded out (and
            // any still waiting for their sentence have appeared).
            while assistantMarks.isShowing || markScheduler?.hasPending == true {
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
    /// (Ollama not running, model missing, etc.). `reason` is the real cause
    /// when the Studio gateway reported one (studio off, busy, model not loaded).
    private func speakErrorFallback(reason: String? = nil) {
        let utterance = reason ?? (isLocalEngineReachable
            ? "hmm, my local brain hiccuped. give it another try."
            : "my local engine isn't running. start ollama and i'll be right back.")
        voiceState = .responding
        Task { try? await speechSynthesizer.speakText(utterance) }
    }

}

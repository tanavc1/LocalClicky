//
//  LocalModels.swift
//  LocalBrainKit
//
//  The on-device models LocalClicky runs through Ollama. The defaults below are
//  deliberately small so they stay responsive on a 16 GB Apple-silicon Mac
//  without throttling the rest of the machine — but they are only *defaults*.
//  Users can point LocalClicky at any model installed in their own Ollama (see
//  `ModelRoleRequirement` for what each role actually needs), which is how the
//  app adapts to more (or less) capable hardware. All inference runs locally —
//  nothing here ever touches a network service outside of localhost.
//

import Foundation

/// Identifiers for the local models LocalClicky uses, plus the default Ollama
/// endpoint. Keeping the defaults in one place means the app, the harness, and
/// the bootstrap script all agree on exactly which weights are expected to exist
/// out of the box.
public enum LocalModels {
    /// Default fast text-only chat model for questions that don't need the
    /// screen. ~2 GB, decodes quickly on M-series GPUs.
    public static let defaultChatModel = "llama3.2:3b"

    /// Default vision-language model that *describes/answers* about the screen
    /// (and powers the screen-aware joke + "give text" about what's visible).
    /// ~1.7 GB — small, fast, and strong at description/VQA. It does **not** emit
    /// pixel coordinates, so pointing turns are routed to `defaultGroundingModel`
    /// instead (see ConversationRouter `.screenPoint`). Measured in
    /// docs/benchmarks/baseline-*.md.
    public static let defaultVisionModel = "moondream"

    /// Default grounding model used only for *pointing* turns — it returns the
    /// pixel coordinates that fly the blue cursor to a UI element. ~3.2 GB and
    /// reliably grounds, which Moondream cannot do. Loaded on demand (or kept
    /// resident on machines with enough RAM — the HardwareAdvisor decides).
    public static let defaultGroundingModel = "qwen2.5vl:3b"

    /// Backwards-compatible aliases (the harness + bootstrap script refer to
    /// these). They are exactly the defaults above.
    public static let chatModel = defaultChatModel
    public static let visionModel = defaultVisionModel
    public static let groundingModel = defaultGroundingModel

    /// Every model the app needs present in Ollama to run fully with the default
    /// configuration. (When the user picks custom models, the *selected* models
    /// are what's checked instead — see `OllamaClient.modelInstalled`.)
    /// The grounding model is *recommended* (pointing degrades gracefully to a
    /// description without it) so it isn't in the hard-required set.
    public static let requiredModels = [defaultChatModel, defaultVisionModel]

    /// The full default arrangement, including the grounding model. Used by the
    /// download flow + engine-status nudge so the signature pointing feature
    /// works out of the box on a fresh install.
    public static let recommendedModels = [defaultChatModel, defaultVisionModel, defaultGroundingModel]

    /// A single, consistent `num_ctx` used for *every* request — text, vision, and
    /// warm-up alike. It has to be roomy enough that a screenshot plus several
    /// turns of history can't overrun Ollama's default 4096 (which 400s the
    /// request), and — critically — it must be identical on every call. Ollama
    /// reloads a model whenever `num_ctx` changes, so if one model serves both the
    /// chat and vision roles (e.g. a single VLM the user picked for both), mixing
    /// context sizes would force an expensive reload on every turn. One value
    /// avoids that entirely. 8192 is plenty for a screenshot + history while still
    /// being cheap on a 3B model's KV cache.
    public static let defaultContextWindow = 8192

    /// Per-role context windows (the autotune "right-size the KV cache" idea). A
    /// pure text turn rarely needs more than this, and a smaller `num_ctx` means
    /// a smaller KV cache → faster prefill (lower time-to-first-word) and less
    /// RAM. Vision turns keep the roomy window because a screenshot plus history
    /// is token-heavy. This is reload-safe as long as a *given model* always gets
    /// the same value (see `CompanionManager.contextWindow(forModel:)`): text and
    /// vision are normally different models, and when one model fills both roles
    /// it gets the vision window in both.
    public static let textContextWindow = 4096
    public static let visionContextWindow = 8192

    /// Default local Ollama endpoint. Overridable so a user running Ollama on a
    /// non-standard port can point the app at it.
    public static let defaultOllamaBaseURL = URL(string: "http://127.0.0.1:11434")!

    /// Whether a vision model can plausibly return pixel coordinates for pointing.
    /// Ollama doesn't expose a "grounding" capability, so this is a deliberately
    /// conservative heuristic: Moondream describes well but cannot ground (it
    /// returns empty output when asked for coordinates — see the baseline
    /// benchmark), so its family is excluded. Everything else is assumed capable
    /// and simply tried. Used so a pointing turn never asks a known-non-grounding
    /// model for coordinates it can't produce.
    public static func isLikelyGroundingCapable(_ model: String) -> Bool {
        !model.lowercased().contains("moondream")
    }
}

/// What a model must be able to do to fill a given LocalClicky role. Used by the
/// model picker to refuse a nonsensical choice (e.g. a text-only model for the
/// vision role) and to explain why. The capability strings match Ollama's
/// `/api/show` `capabilities` array.
public enum ModelRole: String, CaseIterable, Sendable {
    /// The text reasoning model (no screen). Needs ordinary text completion.
    case chat
    /// The screen vision + pointing model. Needs image input ("vision").
    case vision

    /// The Ollama capability this role requires a model to advertise.
    public var requiredCapability: String {
        switch self {
        case .chat: return "completion"
        case .vision: return "vision"
        }
    }

    /// Human-readable name for UI.
    public var displayName: String {
        switch self {
        case .chat: return "Text model"
        case .vision: return "Vision model"
        }
    }

    /// The default model for this role.
    public var defaultModel: String {
        switch self {
        case .chat: return LocalModels.defaultChatModel
        case .vision: return LocalModels.defaultVisionModel
        }
    }
}

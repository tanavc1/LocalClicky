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

    /// Default vision-language model that both answers questions about the screen
    /// and grounds UI elements (returns pixel coordinates) so the blue cursor can
    /// fly to them. ~3.2 GB. This is the local replacement for the cloud vision
    /// model in the original Clicky.
    public static let defaultVisionModel = "qwen2.5vl:3b"

    /// Backwards-compatible aliases (the harness + bootstrap script refer to
    /// these). They are exactly the defaults above.
    public static let chatModel = defaultChatModel
    public static let visionModel = defaultVisionModel

    /// Every model the app needs present in Ollama to run fully with the default
    /// configuration. (When the user picks custom models, the *selected* models
    /// are what's checked instead — see `OllamaClient.modelInstalled`.)
    public static let requiredModels = [defaultChatModel, defaultVisionModel]

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

    /// Default local Ollama endpoint. Overridable so a user running Ollama on a
    /// non-standard port can point the app at it.
    public static let defaultOllamaBaseURL = URL(string: "http://127.0.0.1:11434")!
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

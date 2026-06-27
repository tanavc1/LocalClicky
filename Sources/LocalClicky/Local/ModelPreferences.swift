//
//  ModelPreferences.swift
//  LocalClicky
//
//  Persists which installed Ollama models power LocalClicky's two roles — the
//  text/reasoning model and the screen-vision model. Out of the box these are
//  the bundled defaults (llama3.2:3b and qwen2.5vl:3b), tuned for a 16 GB
//  Apple-silicon Mac. Users on different hardware can point either role at any
//  model in their own Ollama: someone with more memory might pick qwen3-vl:8b for
//  sharper screen grounding; someone on a smaller machine might choose a 1B text
//  model. The vision role is still validated to actually accept images (see
//  CompanionManager.refreshInstalledModels), so a text-only model can't be
//  chosen for a job it can't do.
//

import Foundation
import LocalBrainKit

enum ModelPreferences {
    private static let chatKey = "localClicky.chatModelName"
    private static let visionKey = "localClicky.visionModelName"
    private static let groundingKey = "localClicky.groundingModelName"

    static var chatModel: String {
        get { UserDefaults.standard.string(forKey: chatKey) ?? LocalModels.defaultChatModel }
        set { UserDefaults.standard.set(newValue, forKey: chatKey) }
    }

    static var visionModel: String {
        get { UserDefaults.standard.string(forKey: visionKey) ?? LocalModels.defaultVisionModel }
        set { UserDefaults.standard.set(newValue, forKey: visionKey) }
    }

    /// The grounding model used for pointing turns (the blue cursor's coordinates).
    /// Defaults to qwen2.5vl; the default vision model (Moondream) can't ground.
    static var groundingModel: String {
        get { UserDefaults.standard.string(forKey: groundingKey) ?? LocalModels.defaultGroundingModel }
        set { UserDefaults.standard.set(newValue, forKey: groundingKey) }
    }

    static func model(for role: ModelRole) -> String {
        switch role {
        case .chat: return chatModel
        case .vision: return visionModel
        }
    }

    static func setModel(_ name: String, for role: ModelRole) {
        switch role {
        case .chat: chatModel = name
        case .vision: visionModel = name
        }
    }

    /// Restore all roles to LocalClicky's defaults.
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: chatKey)
        UserDefaults.standard.removeObject(forKey: visionKey)
        UserDefaults.standard.removeObject(forKey: groundingKey)
    }
}

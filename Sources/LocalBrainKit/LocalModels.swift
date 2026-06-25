//
//  LocalModels.swift
//  LocalBrainKit
//
//  The on-device models LocalClicky runs through Ollama. These are deliberately
//  small so they stay responsive on a 16 GB Apple-silicon Mac without throttling
//  the rest of the machine. All three run locally — nothing here ever touches a
//  network service outside of localhost.
//

import Foundation

/// Identifiers for the local models LocalClicky uses, plus the default Ollama
/// endpoint. Keeping them in one place means the app, the harness, and the
/// bootstrap script all agree on exactly which weights are expected to exist.
public enum LocalModels {
    /// Fast text-only chat model for questions that don't need the screen.
    /// ~2 GB, decodes quickly on M-series GPUs.
    public static let chatModel = "llama3.2:3b"

    /// Vision-language model that both answers questions about the screen and
    /// grounds UI elements (returns pixel coordinates) so the blue cursor can
    /// fly to them. ~3.2 GB. This is the local replacement for the cloud vision
    /// model in the original Clicky.
    public static let visionModel = "qwen2.5vl:3b"

    /// Every model the app needs present in Ollama before it can run fully.
    public static let requiredModels = [chatModel, visionModel]

    /// Default local Ollama endpoint. Overridable so a user running Ollama on a
    /// non-standard port can point the app at it.
    public static let defaultOllamaBaseURL = URL(string: "http://127.0.0.1:11434")!
}

//
//  AutotuneBridge.swift
//  LocalBrainKit
//
//  The optional second half of the "autotune" integration. If the user has the
//  `autotune` CLI installed (the owner's tool: https://autotunellm.com), this
//  detects it and layers its richer, machine-measured recommendation on top of
//  the native HardwareAdvisor. It is strictly best-effort: LocalClicky is fully
//  functional without it, and any failure here silently falls back to native.
//
//  autotune has no JSON output, so we parse its text tolerantly — we only try to
//  extract the single most-recommended model id, and never block on it.
//

import Foundation

/// What the bridge could learn from a local `autotune` install.
public struct AutotuneStatus: Sendable, Equatable {
    public let isInstalled: Bool
    public let executablePath: String?
    public let version: String?
    /// The top model id autotune recommends for this machine, if we could parse one.
    public let recommendedModel: String?

    public static let notInstalled = AutotuneStatus(isInstalled: false, executablePath: nil,
                                                    version: nil, recommendedModel: nil)
}

public enum AutotuneBridge {

    /// Locations to probe for the `autotune` binary, beyond whatever is on PATH.
    /// Covers Homebrew, pipx, conda, and the owner's dev venv.
    private static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/autotune",
            "/usr/local/bin/autotune",
            "/opt/anaconda3/bin/autotune",
            "\(home)/.local/bin/autotune",
            "\(home)/Local LLM Optimizer/venv/bin/autotune",
        ]
    }

    /// Finds the autotune executable, preferring `which` (PATH) then known paths.
    /// Returns nil if autotune isn't installed.
    public static func locate() -> String? {
        if let viaWhich = runCapturing("/usr/bin/which", ["autotune"], timeout: 4)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !viaWhich.isEmpty,
           FileManager.default.isExecutableFile(atPath: viaWhich) {
            return viaWhich
        }
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Quick presence + version check (cheap; no model profiling).
    public static func quickStatus() -> AutotuneStatus {
        guard let path = locate() else { return .notInstalled }
        let version = runCapturing(path, ["--version"], timeout: 6)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AutotuneStatus(isInstalled: true, executablePath: path, version: version, recommendedModel: nil)
    }

    /// Full status including autotune's recommended model (runs `autotune
    /// recommend`, which profiles the machine — can take a few seconds). Safe to
    /// call off the main thread. Falls back to quickStatus on any failure.
    public static func fullStatus(amongInstalled installed: [String] = []) -> AutotuneStatus {
        guard let path = locate() else { return .notInstalled }
        let version = runCapturing(path, ["--version"], timeout: 6)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = runCapturing(path, ["recommend", "--mode", "balanced", "--top", "1", "--no-show-hardware"], timeout: 60)
        let recommended = output.flatMap { parseRecommendedModel(from: $0, installed: installed) }
        return AutotuneStatus(isInstalled: true, executablePath: path, version: version, recommendedModel: recommended)
    }

    /// Pulls the first plausible Ollama model id (`name:tag`) out of autotune's
    /// recommend output. Prefers one that's actually installed locally.
    public static func parseRecommendedModel(from text: String, installed: [String]) -> String? {
        // Model ids look like "qwen2.5-coder:7b", "llama3.2:3b", "qwen3:8b".
        let pattern = "[a-zA-Z0-9][a-zA-Z0-9._-]*:[a-zA-Z0-9._-]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [String] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            if let m = match, let r = Range(m.range, in: text) {
                let token = String(text[r])
                // Filter out obvious non-model tokens (urls, times like "9:30").
                if !token.contains("/"), !token.contains("http"), token.first.map({ !$0.isNumber }) ?? false {
                    matches.append(token)
                }
            }
        }
        if matches.isEmpty { return nil }
        // Prefer a recommendation that's actually installed; else the first.
        if !installed.isEmpty, let installedMatch = matches.first(where: { wanted in
            installed.contains { $0 == wanted || $0.hasPrefix(wanted.components(separatedBy: ":")[0]) }
        }) {
            return installedMatch
        }
        return matches.first
    }

    // MARK: - Process helper

    /// Runs a command and returns stdout (best-effort), or nil on failure/timeout.
    /// Times out so a hung autotune can never block the app.
    static func runCapturing(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        // Use the binary directly if it exists, else go through /usr/bin/env.
        if FileManager.default.isExecutableFile(atPath: launchPath) {
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [launchPath] + arguments
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        // Enforce the timeout on a background queue.
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

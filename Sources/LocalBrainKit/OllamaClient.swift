//
//  OllamaClient.swift
//  LocalBrainKit
//
//  Minimal async client for a local Ollama server. LocalClicky never calls a
//  cloud API — every chat and vision request goes to http://127.0.0.1:11434,
//  which serves the on-device models. This client speaks Ollama's /api/chat
//  endpoint, supports streaming (so the cursor's spoken answer can start as
//  soon as the first words decode) and image attachments (for screen vision).
//

import Foundation

/// One message in an Ollama chat request. `imagesBase64` carries raw base64
/// (no data: URI prefix) for vision models; it's empty for text-only turns.
public struct OllamaChatMessage: Sendable {
    public let role: String          // "system" | "user" | "assistant"
    public let content: String
    public let imagesBase64: [String]

    public init(role: String, content: String, imagesBase64: [String] = []) {
        self.role = role
        self.content = content
        self.imagesBase64 = imagesBase64
    }

    public static func system(_ text: String) -> OllamaChatMessage { .init(role: "system", content: text) }
    public static func user(_ text: String, imagesBase64: [String] = []) -> OllamaChatMessage {
        .init(role: "user", content: text, imagesBase64: imagesBase64)
    }
    public static func assistant(_ text: String) -> OllamaChatMessage { .init(role: "assistant", content: text) }
}

/// The result of one fully-streamed chat response, with the same timing fields
/// the UI's latency badge wants (first-token latency is the part the user feels).
public struct OllamaChatResult: Sendable {
    public let text: String
    public let firstTokenLatencySeconds: TimeInterval?
    public let totalDurationSeconds: TimeInterval
    /// Decode speed reported by Ollama (eval_count / eval_duration), if present.
    public let tokensPerSecond: Double?
}

/// One model installed in the local Ollama, as surfaced to the model picker.
public struct InstalledOllamaModel: Sendable, Equatable {
    public let name: String          // e.g. "qwen2.5vl:3b"
    public let sizeBytes: Int64      // on-disk size, for a friendly "3.2 GB" label
    public let family: String?       // e.g. "qwen25vl" (a hint, not authoritative)

    public init(name: String, sizeBytes: Int64, family: String?) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.family = family
    }

    /// A human-friendly size like "3.2 GB" / "780 MB".
    public var sizeDescription: String {
        let gb = Double(sizeBytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(sizeBytes) / 1_000_000
        return String(format: "%.0f MB", mb)
    }
}

public enum OllamaError: Error, LocalizedError {
    /// The local Ollama server isn't reachable on the configured port.
    case serverUnreachable
    /// A model the request needs isn't installed in Ollama yet.
    case modelNotInstalled(String)
    case httpStatus(Int, String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .serverUnreachable:
            return "Can't reach the local Ollama server on 127.0.0.1:11434. Is Ollama running?"
        case .modelNotInstalled(let model):
            return "The local model \"\(model)\" isn't installed. Run: ollama pull \(model)"
        case .httpStatus(let code, let body):
            return "Ollama returned HTTP \(code): \(body)"
        case .malformedResponse(let detail):
            return "Couldn't parse Ollama's response: \(detail)"
        }
    }
}

/// Async client for a local Ollama instance. Thread-safe and cheap to hold for
/// the lifetime of the app — it owns a single long-lived URLSession.
public final class OllamaClient: @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession
    /// A separate session for model downloads (`/api/pull`), which can stream for
    /// many minutes on a multi-GB model. The default session's resource timeout
    /// would abort such a download, so pulls get very generous timeouts instead.
    private let pullSession: URLSession

    public init(baseURL: URL = LocalModels.defaultOllamaBaseURL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.default
        // Generous request timeout: the first call after launch pays the model
        // load cost (a few seconds), and a long spoken answer can stream for a
        // while. Resource timeout bounds a stuck stream. No connectivity wait —
        // this is localhost, so "offline" should fail immediately, not hang.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)

        let pullConfiguration = URLSessionConfiguration.default
        pullConfiguration.timeoutIntervalForRequest = 600       // 10 min between bytes
        pullConfiguration.timeoutIntervalForResource = 7200     // up to 2 h total (big models)
        pullConfiguration.waitsForConnectivity = false
        pullConfiguration.urlCache = nil
        self.pullSession = URLSession(configuration: pullConfiguration)
    }

    // MARK: - Health

    /// True if the Ollama server answers on its tags endpoint. Used at launch
    /// to decide whether to show a "start Ollama" nudge.
    public func isServerReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 4
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// The list of model names currently installed in Ollama (e.g.
    /// "llama3.2:3b"). Throws `serverUnreachable` if Ollama isn't running.
    public func installedModelNames() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 8
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OllamaError.serverUnreachable
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.serverUnreachable
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]] else {
            throw OllamaError.malformedResponse("missing models array in /api/tags")
        }
        return models.compactMap { $0["name"] as? String }
    }

    /// Names of `LocalModels.requiredModels` that aren't installed yet, so the
    /// app can tell the user exactly which `ollama pull` to run.
    public func missingRequiredModels() async throws -> [String] {
        try await missingModels(LocalModels.requiredModels)
    }

    /// Of the given model names, the ones not currently installed in Ollama.
    /// Used for the default required models and for whatever models the user has
    /// selected for the chat/vision roles.
    public func missingModels(_ models: [String]) async throws -> [String] {
        let installed = try await installedModelNames()
        return models.filter { !Self.modelInstalled($0, among: installed) }
    }

    /// True if `wanted` is satisfied by something in `installed`. Ollama stores a
    /// tagless pull as `:latest`, so we normalize both sides before comparing —
    /// that way "llama3.2" matches an installed "llama3.2:latest" while a specific
    /// tag like "llama3.2:3b" still only matches its own tag. Pure + static so it
    /// can be unit-tested from the harness without a running server.
    public static func modelInstalled(_ wanted: String, among installed: [String]) -> Bool {
        func normalize(_ name: String) -> String {
            name.contains(":") ? name : name + ":latest"
        }
        let target = normalize(wanted)
        return installed.contains { normalize($0) == target }
    }

    /// Every model installed in Ollama, with size + family, for the model picker.
    public func listInstalledModels() async throws -> [InstalledOllamaModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 8
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OllamaError.serverUnreachable
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.serverUnreachable
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]] else {
            throw OllamaError.malformedResponse("missing models array in /api/tags")
        }
        return models.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let size = (entry["size"] as? NSNumber)?.int64Value ?? 0
            let family = (entry["details"] as? [String: Any])?["family"] as? String
            return InstalledOllamaModel(name: name, sizeBytes: size, family: family)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The capabilities Ollama reports for a model (e.g. `["completion", "vision"]`).
    /// Used to validate that a model the user picked for the vision role can
    /// actually accept images. Returns an empty set if the model or server can't
    /// be queried, so callers can decide how strict to be.
    public func capabilities(of model: String) async -> Set<String> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilities = payload["capabilities"] as? [String] else {
            return []
        }
        return Set(capabilities)
    }

    // MARK: - Model download (/api/pull)

    /// Progress for an in-flight `ollama pull`. `fraction` is 0…1 when byte
    /// counts are known (the big "downloading" layers), else 0 during the
    /// manifest/verify phases.
    public struct PullProgress: Sendable, Equatable {
        public let status: String
        public let completedBytes: Int64
        public let totalBytes: Int64
        public var fraction: Double {
            totalBytes > 0 ? min(1.0, max(0.0, Double(completedBytes) / Double(totalBytes))) : 0
        }
        public var isComplete: Bool { status.lowercased().contains("success") }
    }

    /// Parses one newline-delimited JSON object from `/api/pull` into progress.
    /// Pure + static so it can be unit-tested from the harness. Returns nil for
    /// blank lines / unparseable input, and throws via the returned error string.
    public static func parsePullLine(_ line: String) -> (progress: PullProgress?, error: String?) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        if let error = obj["error"] as? String { return (nil, error) }
        let status = obj["status"] as? String ?? ""
        let completed = (obj["completed"] as? NSNumber)?.int64Value ?? 0
        let total = (obj["total"] as? NSNumber)?.int64Value ?? 0
        return (PullProgress(status: status, completedBytes: completed, totalBytes: total), nil)
    }

    /// Downloads (pulls) a model into Ollama, streaming progress. The stream
    /// finishes when the pull succeeds, or throws on error (incl. server
    /// unreachable). Cancelling the consuming task cancels the download.
    public func pullModel(_ name: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await pullSession.bytes(for: request)
                    } catch {
                        throw OllamaError.serverUnreachable
                    }
                    guard let http = response as? HTTPURLResponse else {
                        throw OllamaError.malformedResponse("no HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        throw OllamaError.httpStatus(http.statusCode, "pull failed")
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let parsed = Self.parsePullLine(line)
                        if let error = parsed.error { throw OllamaError.httpStatus(500, error) }
                        if let progress = parsed.progress { continuation.yield(progress) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Streaming chat

    /// Sends one chat turn and streams the response. `onText` is invoked with the
    /// accumulated text so far (not deltas) each time new tokens arrive — the same
    /// ergonomics the rest of LocalClicky already uses for progressive display.
    ///
    /// - Parameters:
    ///   - model: an installed Ollama model name.
    ///   - messages: the full prompt (system + history + current user turn).
    ///   - temperature: sampling temperature.
    ///   - maxTokens: hard cap on generated tokens (nil = model default).
    ///   - keepAlive: how long Ollama keeps the model resident after the call.
    ///     "10m" keeps it warm between questions so the next answer is instant.
    ///   - contextWindow: num_ctx for the model. Ollama's default (4096) can be
    ///     overrun by a screenshot plus several turns of history, which 400s the
    ///     request. A roomier, *consistent* value avoids that — and it must be the
    ///     same on every call (warm-up included), or Ollama reloads the model and
    ///     the warm-up is wasted.
    @discardableResult
    public func streamChat(
        model: String,
        messages: [OllamaChatMessage],
        temperature: Double = 0.7,
        maxTokens: Int? = nil,
        keepAlive: String = "10m",
        contextWindow: Int = 8192,
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> OllamaChatResult {
        var requestOptions: [String: Any] = ["temperature": temperature, "num_ctx": contextWindow]
        if let maxTokens { requestOptions["num_predict"] = maxTokens }

        let messagePayload: [[String: Any]] = messages.map { message in
            var entry: [String: Any] = ["role": message.role, "content": message.content]
            if !message.imagesBase64.isEmpty {
                entry["images"] = message.imagesBase64
            }
            return entry
        }

        let body: [String: Any] = [
            "model": model,
            "messages": messagePayload,
            "stream": true,
            "keep_alive": keepAlive,
            "options": requestOptions,
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let requestStartDate = Date()

        let byteStream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (byteStream, response) = try await session.bytes(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OllamaError.serverUnreachable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.malformedResponse("no HTTP response")
        }
        guard httpResponse.statusCode == 200 else {
            // Drain the body for the error message (e.g. model-not-found).
            var errorChunks: [String] = []
            for try await line in byteStream.lines { errorChunks.append(line) }
            let errorBody = errorChunks.joined(separator: "\n")
            if httpResponse.statusCode == 404 || errorBody.lowercased().contains("not found") {
                throw OllamaError.modelNotInstalled(model)
            }
            throw OllamaError.httpStatus(httpResponse.statusCode, errorBody)
        }

        // Ollama streams newline-delimited JSON objects, one per chunk.
        var accumulatedText = ""
        var firstTokenLatencySeconds: TimeInterval?
        var reportedTokensPerSecond: Double?

        for try await line in byteStream.lines {
            try Task.checkCancellation()
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty,
                  let lineData = trimmedLine.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let message = chunk["message"] as? [String: Any],
               let contentDelta = message["content"] as? String,
               !contentDelta.isEmpty {
                if firstTokenLatencySeconds == nil {
                    firstTokenLatencySeconds = Date().timeIntervalSince(requestStartDate)
                }
                accumulatedText += contentDelta
                onText(accumulatedText)
            }

            // The final chunk carries timing/eval counters.
            if let isDone = chunk["done"] as? Bool, isDone {
                if let evalCount = chunk["eval_count"] as? Double,
                   let evalDurationNanos = chunk["eval_duration"] as? Double,
                   evalDurationNanos > 0 {
                    reportedTokensPerSecond = evalCount / (evalDurationNanos / 1_000_000_000)
                }
            }
        }

        try Task.checkCancellation()

        return OllamaChatResult(
            text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
            firstTokenLatencySeconds: firstTokenLatencySeconds,
            totalDurationSeconds: Date().timeIntervalSince(requestStartDate),
            tokensPerSecond: reportedTokensPerSecond
        )
    }
}

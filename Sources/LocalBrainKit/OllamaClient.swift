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
        let installed = Set(try await installedModelNames())
        return LocalModels.requiredModels.filter { required in
            // Ollama lets a tagless name match its :latest; also tolerate the
            // exact tagged name. Match on the bare repo if the user pulled a
            // differently-tagged build of the same model family.
            !installed.contains(required)
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

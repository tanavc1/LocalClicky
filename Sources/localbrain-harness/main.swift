//
//  localbrain-harness
//
//  A command-line harness that exercises LocalClicky's entire local inference
//  pipeline end-to-end against the real Ollama models — no GUI, no mic, no
//  screen permissions needed. This is how we verify the "brain" actually works:
//  text chat, screen vision Q&A, and UI-element pointing (the coordinates that
//  drive the blue cursor).
//
//  Usage:
//    localbrain-harness                         # health + text chat only
//    localbrain-harness <image.png>             # + vision Q&A + pointing
//    localbrain-harness <image.png> "question"  # custom screen question
//

import Foundation
import LocalBrainKit

func loadImageBase64(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return data.base64EncodedString()
}

func fmt(_ value: TimeInterval?) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.2fs", value)
}

/// Reads pixel dimensions from a PNG header without decoding the whole image.
func pngPixelSize(path: String) -> (Int, Int)? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let bytes = [UInt8](data)
    guard bytes.count > 24, bytes[0] == 0x89, bytes[1] == 0x50 else { return nil }
    let width = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
    let height = Int(bytes[20]) << 24 | Int(bytes[21]) << 16 | Int(bytes[22]) << 8 | Int(bytes[23])
    return (width, height)
}

import CoreGraphics
import ImageIO
import AppKit

// MARK: - Benchmark support

/// Simple latency accumulator. We report the mean of the *warm* runs (the first
/// run is discarded so the model-load cost doesn't pollute the steady-state
/// number the user actually feels question-to-question).
private struct LatencySamples {
    var firstToken: [TimeInterval] = []
    var total: [TimeInterval] = []
    var tokensPerSecond: [Double] = []

    mutating func record(_ result: OllamaChatResult) {
        if let ft = result.firstTokenLatencySeconds { firstToken.append(ft) }
        total.append(result.totalDurationSeconds)
        if let tps = result.tokensPerSecond { tokensPerSecond.append(tps) }
    }

    private func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    var meanFirstToken: TimeInterval { mean(firstToken) }
    var meanTotal: TimeInterval { mean(total) }
    var meanTokensPerSecond: Double { mean(tokensPerSecond) }
}

/// Mutable holder so the @Sendable streaming callback can record when the first
/// complete spoken sentence becomes available.
private final class FirstSentenceTimer: @unchecked Sendable {
    let start = Date()
    var firstSentenceAt: TimeInterval?
    var spokenLength = 0
}

/// Downscales encoded image data to a target long edge and re-encodes as JPEG,
/// returning the bytes plus the new pixel dimensions. Used by the image-size
/// sweep so we can measure how prefill latency trades against the resolution the
/// vision model actually sees. Mirrors the app's capture (JPEG, q0.8).
private func resizedJPEG(from data: Data, longEdge: Int, compression: CGFloat = 0.8) -> (data: Data, width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = cgImage.width, height = cgImage.height
    let scale = Double(longEdge) / Double(max(width, height))
    let newWidth = max(1, Int(Double(width) * scale))
    let newHeight = max(1, Int(Double(height) * scale))
    guard let context = CGContext(
        data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
    guard let scaled = context.makeImage(),
          let jpeg = NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: compression]) else { return nil }
    return (jpeg, newWidth, newHeight)
}

/// Runs the same kind of requests the app makes and prints averaged latency, so
/// we can prove before/after the latency work. Discards a warm-up run for each
/// configuration.
///   localbrain-harness --benchmark [image.png] [iterations]
func runBenchmark(imagePath: String?, iterations: Int) async {
    let client = OllamaClient()
    print("=== LocalClicky latency benchmark (\(iterations) warm runs each) ===")
    guard await client.isServerReachable() else {
        print("❌ Ollama not reachable on \(client.baseURL). Start it: ollama serve")
        exit(1)
    }

    // --- Text chat ---
    print("\n--- text chat (\(LocalModels.chatModel)) ---")
    let textPrompt = "what's 12 times 8? answer in one short sentence."
    do {
        // warm-up (discarded)
        _ = try await client.streamChat(model: LocalModels.chatModel,
            messages: [.system(LocalPrompts.textVoiceResponse), .user(textPrompt)],
            temperature: 0.2, maxTokens: 80, onText: { _ in })
        var samples = LatencySamples()
        for _ in 0..<iterations {
            let result = try await client.streamChat(model: LocalModels.chatModel,
                messages: [.system(LocalPrompts.textVoiceResponse), .user(textPrompt)],
                temperature: 0.2, maxTokens: 80, onText: { _ in })
            samples.record(result)
        }
        print(String(format: "  first-token %.2fs | total %.2fs | %.0f tok/s",
                     samples.meanFirstToken, samples.meanTotal, samples.meanTokensPerSecond))
    } catch {
        print("  ❌ text chat failed: \(error.localizedDescription)")
    }

    // --- Perceived speech latency: when can the companion START talking? ---
    // The old pipeline waited for the FULL answer before speaking; the new one
    // speaks the first sentence as soon as it's complete. Both are measured here
    // from one streamed response.
    print("\n--- perceived speech latency (text answer, when speech can begin) ---")
    do {
        let timer = FirstSentenceTimer()
        let result = try await client.streamChat(
            model: LocalModels.chatModel,
            messages: [.system(LocalPrompts.textVoiceResponse),
                       .user("explain what git is, in two short sentences.")],
            temperature: 0.3, maxTokens: 120,
            onText: { accumulated in
                guard timer.firstSentenceAt == nil else { return }
                let speakable = SpokenTextSegmenter.speakablePrefix(accumulated)
                if let next = SpokenTextSegmenter.nextCompleteSentences(
                    speakable: speakable, alreadySpoken: timer.spokenLength) {
                    timer.spokenLength = next.newSpokenLength
                    timer.firstSentenceAt = Date().timeIntervalSince(timer.start)
                }
            })
        let full = result.totalDurationSeconds
        let first = timer.firstSentenceAt ?? full
        print(String(format: "  new: start talking at first sentence  %.2fs", first))
        print(String(format: "  old: waited for full answer           %.2fs", full))
        print(String(format: "  → speech begins %.2fs sooner (%.0f%%)", full - first,
                     full > 0 ? (full - first) / full * 100 : 0))
    } catch {
        print("  ❌ perceived-latency test failed: \(error.localizedDescription)")
    }

    // --- Vision Q&A + image-size sweep ---
    guard let imagePath, let rawData = FileManager.default.contents(atPath: imagePath) else {
        print("\n(no image given — skipping vision sweep. Pass a screenshot path to benchmark vision.)")
        return
    }
    let question = "where do i click to open settings?"
    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
    print("\n--- vision (\(LocalModels.visionModel)) on \(imagePath) — image long-edge sweep ---")
    print("  " + pad("size", 12) + pad("bytes(KB)", 11) + pad("first-token", 13) + pad("total", 12) + "pointed?")
    for longEdge in [1280, 1100, 1024, 896] {
        guard let resized = resizedJPEG(from: rawData, longEdge: longEdge) else {
            print("  \(longEdge): resize failed"); continue
        }
        let base64 = resized.data.base64EncodedString()
        let systemPrompt = LocalPrompts.screenVoiceResponse(
            imageWidthInPixels: resized.width, imageHeightInPixels: resized.height)
        do {
            _ = try await client.streamChat(model: LocalModels.visionModel,
                messages: [.system(systemPrompt), .user(question, imagesBase64: [base64])],
                temperature: 0.2, maxTokens: 160, onText: { _ in })
            var samples = LatencySamples()
            var pointedCount = 0
            for _ in 0..<iterations {
                let result = try await client.streamChat(model: LocalModels.visionModel,
                    messages: [.system(systemPrompt), .user(question, imagesBase64: [base64])],
                    temperature: 0.2, maxTokens: 160, onText: { _ in })
                samples.record(result)
                if PointingTagParser.parse(from: result.text).hasPoint { pointedCount += 1 }
            }
            let label = "\(resized.width)x\(resized.height)"
            print("  " + pad(label, 12) + pad("\(resized.data.count / 1024)", 11)
                  + pad(String(format: "%.2fs", samples.meanFirstToken), 13)
                  + pad(String(format: "%.2fs", samples.meanTotal), 12)
                  + "\(pointedCount)/\(iterations)")
        } catch {
            print("  \(longEdge): ❌ \(error.localizedDescription)")
        }
    }
}

// MARK: - Benchmark suite (structured, reproducible before/after)

/// One model's measured numbers, JSON-encoded into the report so before/after
/// runs can be diffed mechanically rather than eyeballed.
struct BenchRunResult: Codable {
    let model: String
    let role: String                 // "text" | "vision"
    let samples: Int                 // prompt runs that succeeded
    let meanFirstTokenSeconds: Double
    let meanTotalSeconds: Double
    let meanTokensPerSecond: Double
    let pointParseRate: Double       // fraction that returned a [POINT] tag (vision)
    let pointInBoundsRate: Double    // fraction whose coords landed inside the image (vision)
}

/// The full report written to docs/benchmarks/. Captures enough provenance
/// (commit, image, hardware snapshot) that a run is meaningful months later.
struct BenchSuiteReport: Codable {
    let label: String                // "baseline" | "after" | custom
    let timestamp: String
    let gitCommit: String
    let image: String
    let imageWidth: Int
    let imageHeight: Int
    let iterations: Int
    let textModel: String
    let visionModel: String
    let ollamaPs: String
    let results: [BenchRunResult]
}

/// Shells out to a command and returns its trimmed stdout (best-effort, "" on failure).
/// Used for `ollama ps` (resident-model RAM snapshot) and the git commit stamp.
func shellCapture(_ command: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return "" }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Benchmarks the text model on a few representative prompts (latency only).
func benchTextModel(_ client: OllamaClient, model: String, prompts: [String], iterations: Int) async -> BenchRunResult {
    var samples = LatencySamples()
    // Discard one warm-up so steady-state numbers aren't polluted by model load.
    // Uses the app's per-role text context window (the autotune KV right-sizing).
    _ = try? await client.streamChat(model: model, messages: [.system(LocalPrompts.textVoiceResponse), .user("hi")],
                                     temperature: 0.2, maxTokens: 8,
                                     contextWindow: LocalModels.textContextWindow, onText: { _ in })
    for prompt in prompts {
        for _ in 0..<iterations {
            if let result = try? await client.streamChat(
                model: model,
                messages: [.system(LocalPrompts.textVoiceResponse), .user(prompt)],
                temperature: 0.2, maxTokens: 100,
                contextWindow: LocalModels.textContextWindow, onText: { _ in }) {
                samples.record(result)
            }
        }
    }
    return BenchRunResult(model: model, role: "text", samples: samples.total.count,
                          meanFirstTokenSeconds: samples.meanFirstToken,
                          meanTotalSeconds: samples.meanTotal,
                          meanTokensPerSecond: samples.meanTokensPerSecond,
                          pointParseRate: 0, pointInBoundsRate: 0)
}

/// Benchmarks one vision model on UI-grounding prompts. Beyond latency, it
/// measures how often the model returns a *parseable* [POINT] tag and how often
/// those coordinates land inside the image — an honest, reproducible proxy for
/// "can the blue cursor actually rely on this model to point" (true target
/// accuracy would need hand-labeled ground truth, which this does not claim).
func benchVisionModel(_ client: OllamaClient, model: String, imageBase64: String,
                      width: Int, height: Int, prompts: [String], iterations: Int) async -> BenchRunResult {
    // The dedicated directive pointing prompt (forces a well-formed tag), at the
    // app's per-role vision context window.
    let systemPrompt = LocalPrompts.screenPointResponse(imageWidthInPixels: width, imageHeightInPixels: height)
    var samples = LatencySamples()
    var parsed = 0, inBounds = 0, attempts = 0
    // Warm-up (discarded).
    _ = try? await client.streamChat(model: model,
        messages: [.system(systemPrompt), .user(prompts.first ?? "what's on screen?", imagesBase64: [imageBase64])],
        temperature: 0.2, maxTokens: 160, contextWindow: LocalModels.visionContextWindow, onText: { _ in })
    for prompt in prompts {
        for _ in 0..<iterations {
            attempts += 1
            guard let result = try? await client.streamChat(
                model: model,
                messages: [.system(systemPrompt), .user(prompt, imagesBase64: [imageBase64])],
                temperature: 0.2, maxTokens: 160, contextWindow: LocalModels.visionContextWindow, onText: { _ in }) else { continue }
            samples.record(result)
            let pointing = PointingTagParser.parse(from: result.text)
            if pointing.hasPoint, let center = pointing.centerInImagePixels {
                parsed += 1
                if center.x >= 0, center.x <= CGFloat(width), center.y >= 0, center.y <= CGFloat(height) {
                    inBounds += 1
                }
            }
        }
    }
    let denom = Double(max(attempts, 1))
    return BenchRunResult(model: model, role: "vision", samples: samples.total.count,
                          meanFirstTokenSeconds: samples.meanFirstToken,
                          meanTotalSeconds: samples.meanTotal,
                          meanTokensPerSecond: samples.meanTokensPerSecond,
                          pointParseRate: Double(parsed) / denom,
                          pointInBoundsRate: Double(inBounds) / denom)
}

/// Structured before/after benchmark. Measures the text model plus every
/// installed vision candidate (so qwen2.5vl and moondream can be compared
/// head-to-head), then writes a JSON + Markdown report under docs/benchmarks/.
///   localbrain-harness --benchmark-suite <image.png> [iterations] [label]
func runBenchmarkSuite(imagePath: String, iterations: Int, label: String) async {
    let client = OllamaClient()
    print("=== LocalClicky benchmark suite — \(label) (\(iterations)x each prompt) ===")
    guard await client.isServerReachable() else {
        print("❌ Ollama not reachable on \(client.baseURL). Start it: ollama serve"); exit(1)
    }
    guard let rawData = FileManager.default.contents(atPath: imagePath) else {
        print("❌ couldn't read image at \(imagePath)"); exit(1)
    }
    // Prefer the PNG header; fall back to a JPEG decode for size.
    var (width, height) = pngPixelSize(path: imagePath) ?? (0, 0)
    if width == 0 || height == 0 {
        if let resized = resizedJPEG(from: rawData, longEdge: 4096, compression: 1.0) { (width, height) = (resized.width, resized.height) }
    }
    let imageBase64 = rawData.base64EncodedString()

    let textPrompts = [
        "what's 12 times 8? answer in one short sentence.",
        "explain what git is, in two short sentences.",
        "what's the capital of france?",
    ]
    let pointPrompts = [
        "where do i click to open settings?",
        "point at the search bar.",
        "where is the close button?",
        "show me where to type.",
    ]

    var results: [BenchRunResult] = []

    print("\n--- text model: \(LocalModels.chatModel) ---")
    let textResult = await benchTextModel(client, model: LocalModels.chatModel, prompts: textPrompts, iterations: iterations)
    results.append(textResult)
    print(String(format: "  TTFT %.2fs | total %.2fs | %.0f tok/s",
                 textResult.meanFirstTokenSeconds, textResult.meanTotalSeconds, textResult.meanTokensPerSecond))

    // Every installed vision candidate, so the swap can be judged on real numbers.
    let installed = (try? await client.listInstalledModels())?.map { $0.name } ?? []
    var visionCandidates: [String] = []
    for candidate in ["qwen2.5vl:3b", "moondream", "qwen3-vl:8b"] where OllamaClient.modelInstalled(candidate, among: installed) {
        // Normalize moondream → the actual installed tag so the request matches.
        let resolved = installed.first { OllamaClient.modelInstalled(candidate, among: [$0]) } ?? candidate
        if !visionCandidates.contains(resolved) { visionCandidates.append(resolved) }
    }
    for model in visionCandidates {
        print("\n--- vision model: \(model) [\(width)x\(height)] ---")
        let result = await benchVisionModel(client, model: model, imageBase64: imageBase64,
                                            width: width, height: height, prompts: pointPrompts, iterations: iterations)
        results.append(result)
        print(String(format: "  TTFT %.2fs | total %.2fs | %.0f tok/s | point-parse %.0f%% | in-bounds %.0f%%",
                     result.meanFirstTokenSeconds, result.meanTotalSeconds, result.meanTokensPerSecond,
                     result.pointParseRate * 100, result.pointInBoundsRate * 100))
    }

    // Provenance + write the report.
    let stamp = ISO8601DateFormatter().string(from: Date())
    let report = BenchSuiteReport(
        label: label, timestamp: stamp,
        gitCommit: shellCapture("git", ["rev-parse", "--short", "HEAD"]),
        image: imagePath, imageWidth: width, imageHeight: height, iterations: iterations,
        textModel: LocalModels.chatModel, visionModel: LocalModels.visionModel,
        ollamaPs: shellCapture("ollama", ["ps"]), results: results)

    let dateOnly = String(stamp.prefix(10))
    let outDir = "docs/benchmarks"
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let jsonPath = "\(outDir)/\(label)-\(dateOnly).json"
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(report) { try? data.write(to: URL(fileURLWithPath: jsonPath)) }

    // Human-readable Markdown alongside the JSON.
    var md = "# LocalClicky benchmark — \(label)\n\n"
    md += "- Date: \(stamp)\n- Commit: \(report.gitCommit)\n- Image: \(imagePath) (\(width)x\(height))\n- Iterations per prompt: \(iterations)\n\n"
    md += "| Model | Role | TTFT (s) | Total (s) | tok/s | Point-parse | In-bounds |\n"
    md += "|---|---|---:|---:|---:|---:|---:|\n"
    for r in results {
        let pp = r.role == "vision" ? String(format: "%.0f%%", r.pointParseRate * 100) : "—"
        let ib = r.role == "vision" ? String(format: "%.0f%%", r.pointInBoundsRate * 100) : "—"
        md += String(format: "| %@ | %@ | %.2f | %.2f | %.0f | %@ | %@ |\n",
                     r.model, r.role, r.meanFirstTokenSeconds, r.meanTotalSeconds, r.meanTokensPerSecond, pp, ib)
    }
    md += "\n```\nollama ps:\n\(report.ollamaPs)\n```\n"
    let mdPath = "\(outDir)/\(label)-\(dateOnly).md"
    try? md.write(toFile: mdPath, atomically: true, encoding: .utf8)

    print("\n📊 wrote \(jsonPath)\n📊 wrote \(mdPath)")
}

/// A flat-grey JPEG for the ink-image self-test checks.
func inkJPEG(width: Int, height: Int) -> Data? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

/// Dependency-free assertion runner so the pointing-tag parser can be verified
/// on a Command-Line-Tools-only machine (XCTest needs full Xcode).
func runSelfTest() -> Never {
    var failures = 0
    func check(_ name: String, _ condition: Bool) {
        print((condition ? "✅ " : "❌ ") + name)
        if !condition { failures += 1 }
    }

    let t1 = PointingTagParser.parse(from: "you'll want the color inspector. [POINT:1100,42:color inspector]")
    check("classic [POINT:x,y:label]", t1.centerInImagePixels == CGPoint(x: 1100, y: 42)
          && t1.label == "color inspector" && t1.spokenText == "you'll want the color inspector.")

    let t2 = PointingTagParser.parse(from: "that's on your other monitor. [POINT:400,300:terminal:screen2]")
    check("screen number suffix", t2.centerInImagePixels == CGPoint(x: 400, y: 300)
          && t2.label == "terminal" && t2.screenNumber == 2)

    let t3 = PointingTagParser.parse(from: "html is the skeleton. [POINT:none]")
    check("[POINT:none] → no point", !t3.hasPoint && t3.spokenText == "html is the skeleton.")

    let t4 = PointingTagParser.parse(from: "click record. [POINT:932,415,978,436:rec]")
    check("box inside POINT → center", t4.centerInImagePixels == CGPoint(x: 955, y: 425.5) && t4.label == "rec")

    let t5 = PointingTagParser.parse(from: "here it is [589,714,692,750:Export]")
    check("bare box fallback → center", t5.centerInImagePixels == CGPoint(x: 640.5, y: 732)
          && t5.label == "Export" && t5.spokenText == "here it is")

    let t6 = PointingTagParser.parse(from: "just a normal answer with no pointing")
    check("no tag → whole text", !t6.hasPoint && t6.spokenText == "just a normal answer with no pointing")

    let t7 = PointingTagParser.parse(from: "look here [POINT:10,20:a] and final [POINT:30,40:b]")
    check("multiple tags: last wins, all stripped", t7.centerInImagePixels == CGPoint(x: 30, y: 40)
          && !t7.spokenText.contains("POINT"))

    // qwen2.5-vl's actual attribute output format.
    let t8 = PointingTagParser.parse(from: "the gear icon, top right. [POINT x=\"736\" y=\"45\"]")
    check("attribute [POINT x=.. y=..] form", t8.centerInImagePixels == CGPoint(x: 736, y: 45)
          && t8.spokenText == "the gear icon, top right.")
    let t9 = PointingTagParser.parse(from: "here it is [POINT x1=\"10\" y1=\"20\" x2=\"30\" y2=\"40\" label=\"save\"]")
    check("attribute box form → center + label", t9.centerInImagePixels == CGPoint(x: 20, y: 30) && t9.label == "save")
    let t10 = PointingTagParser.parse(from: "no good target here [POINT:none]")
    check("attribute parser still honors none", !t10.hasPoint)

    // --- ConversationRouter ---
    // Default daily context: vision mode on, screen available.
    func ctx(prevScreen: Bool = false, history: Bool = false,
             vision: Bool = true, screen: Bool = true) -> ConversationRouter.Context {
        .init(visionModeSelected: vision, screenAvailable: screen,
              previousTurnUsedScreen: prevScreen, hasConversationHistory: history)
    }
    func route(_ s: String, _ c: ConversationRouter.Context) -> ConversationRoute {
        ConversationRouter.route(transcript: s, context: c)
    }
    check("math → text", route("what's 3 times 5", ctx()) == .text)
    check("math follow-up → text", route("add 2 to that", ctx(prevScreen: false, history: true)) == .text)
    check("general knowledge → text", route("what's the capital of france", ctx()) == .text)
    // Pointing intent → screenPoint (grounding model); describing → screen (Moondream).
    check("'where do i click' → screenPoint", route("where do i click to start recording", ctx()) == .screenPoint)
    check("'point at the search bar' → screenPoint", route("point at the search bar", ctx()) == .screenPoint)
    check("'which button do i press' → screenPoint", route("which button do i press to save", ctx()) == .screenPoint)
    check("'show me where to type' → screenPoint", route("show me where to type my password", ctx()) == .screenPoint)
    // A pointing question that mentions "open settings" must point, not launch the app.
    check("'where do i click to open settings' → screenPoint (not openApp)",
          route("where do i click to open settings", ctx()) == .screenPoint)
    check("'point at the gmail tab' → screenPoint (not browser)",
          route("point at the gmail tab", ctx()) == .screenPoint)
    check("plain 'open settings' still → openApp", route("open the settings app", ctx()) == .openApp)
    check("screen 'this button' → screen (describe)", route("what does this button do", ctx()) == .screen)
    check("screen 'explain this error' → screen", route("explain this error", ctx()) == .screen)
    check("screen 'what's on my screen' → screen", route("what's on my screen right now", ctx()) == .screen)
    check("browser new tab → browserCommand", route("open a new tab and go to gmail", ctx()) == .browserCommand)
    check("browser gmail draft → browserCommand", route("go to my gmail and open up a draft", ctx()) == .browserCommand)
    check("browser works in text mode", route("open youtube", ctx(vision: false)) == .browserCommand)
    check("'open the file menu' is NOT browser", route("open the file menu", ctx()) == .screen)
    check("text mode never screens", route("what's on my screen", ctx(vision: false)) == .text)
    check("no screen permission falls back to text", route("where do i click", ctx(screen: false)) == .text)
    // Default is the text assistant — a plain question must NOT screenshot/describe.
    check("'tell me a joke' → text (not screen)", route("tell me a joke", ctx()) == .text)
    check("'what time is it' → text (not screen)", route("what time is it", ctx()) == .text)
    check("'explain quantum computing' → text (not screen)", route("explain quantum computing", ctx()) == .text)
    // Imperative "click X" actually clicks; "where do i click" only points.
    check("'click the submit button' → screenClick", route("click the submit button", ctx()) == .screenClick)
    check("'press the play button' → screenClick", route("press the play button", ctx()) == .screenClick)
    check("'go ahead and click the link' → screenClick", route("go ahead and click the link", ctx()) == .screenClick)
    check("'where do i click' stays screenPoint (not click)", route("where do i click to save", ctx()) == .screenPoint)
    check("click with no screen → text", route("click the submit button", ctx(screen: false)) == .text)

    // --- SpokenTextSegmenter (streaming TTS) ---
    check("speakablePrefix cuts at pointing tag",
          SpokenTextSegmenter.speakablePrefix("you'll want the toolbar. [POINT:10,20:x]") == "you'll want the toolbar. ")
    check("speakablePrefix passes plain text",
          SpokenTextSegmenter.speakablePrefix("just a normal answer") == "just a normal answer")
    let seg1 = SpokenTextSegmenter.nextCompleteSentences(speakable: "you'll find it up top. it's blue", alreadySpoken: 0)
    check("first complete sentence emitted", seg1?.text == "you'll find it up top.")
    check("partial trailing sentence withheld",
          SpokenTextSegmenter.nextCompleteSentences(speakable: "it's blue", alreadySpoken: 0) == nil)
    check("decimal not split mid-stream",
          SpokenTextSegmenter.nextCompleteSentences(speakable: "the answer is 3.5 meters", alreadySpoken: 0) == nil)
    let seg2 = SpokenTextSegmenter.nextCompleteSentences(speakable: "the answer is 3.5 meters. ", alreadySpoken: 0)
    check("decimal intact when sentence completes", seg2?.text == "the answer is 3.5 meters.")
    check("remainder returns final sentence",
          SpokenTextSegmenter.remainder(speakable: "all done now", alreadySpoken: 0) == "all done now")

    // --- BrowserCommandPlanner ---
    let bp1 = BrowserCommandPlanner.plan(for: "open a new tab, go to my gmail, and open up a draft")
    check("gmail draft → compose url", bp1.actions.count == 1 && bp1.actions[0].url.contains("view=cm"))
    let bp2 = BrowserCommandPlanner.plan(for: "open gmail")
    check("open gmail → inbox url", bp2.actions.first?.url == "https://mail.google.com/mail/u/0/")
    let bp3 = BrowserCommandPlanner.plan(for: "search for swift concurrency")
    check("search → google query", bp3.actions.first?.url.contains("search?q=swift") == true)
    let bp4 = BrowserCommandPlanner.plan(for: "open youtube and reddit")
    check("two sites → two actions", bp4.actions.count == 2)
    let bp5 = BrowserCommandPlanner.plan(for: "go to youtube and go to david dobriks channel")
    check("youtube channel request → youtube channel search",
          bp5.actions.count == 1
          && bp5.actions[0].url.contains("youtube.com/results")
          && bp5.actions[0].url.contains("david"))
    let bp6 = BrowserCommandPlanner.plan(for: "search for coffee shops on google maps")
    check("maps scoped search → maps search url",
          bp6.actions.first?.url.contains("google.com/maps/search") == true
          && bp6.actions.first?.url.contains("coffee") == true)
    let bp7 = BrowserCommandPlanner.plan(for: "open github and search for localclicky")
    check("github scoped search → github search url",
          bp7.actions.first?.url.contains("github.com/search") == true
          && bp7.actions.first?.url.contains("localclicky") == true)
    check("unknown command not understood",
          BrowserCommandPlanner.plan(for: "open the file menu").isUnderstood == false)

    // --- AppCommandPlanner (open/launch local apps) ---
    check("'launch spotify' → app name spotify",
          AppCommandPlanner.appLaunchName(from: "launch spotify") == "spotify")
    check("'open the notes app' → notes",
          AppCommandPlanner.appLaunchName(from: "open the notes app") == "notes")
    check("'open notes and write a list' → notes",
          AppCommandPlanner.appLaunchName(from: "open notes and write a list") == "notes")
    check("'open the activity monitor app' → activity monitor",
          AppCommandPlanner.appLaunchName(from: "open the activity monitor app") == "activity monitor")
    check("'launch visual studio code' → full name",
          AppCommandPlanner.appLaunchName(from: "launch visual studio code") == "visual studio code")
    check("bare 'open notes' (known app) → notes",
          AppCommandPlanner.appLaunchName(from: "open notes") == "notes")
    check("'open the file menu' is NOT an app launch",
          !AppCommandPlanner.isAppLaunch("open the file menu"))
    check("'open gmail' is NOT an app launch (stays browser)",
          !AppCommandPlanner.isAppLaunch("open gmail"))
    check("'open up a draft' is NOT an app launch",
          !AppCommandPlanner.isAppLaunch("open up a draft"))

    // --- New routes ---
    check("'launch spotify' → openApp", route("launch spotify", ctx()) == .openApp)
    check("'open the terminal app' → openApp", route("open the terminal app", ctx()) == .openApp)
    check("'open notes' → openApp", route("open notes", ctx()) == .openApp)
    check("app launch wins over browser for explicit phrasing",
          route("launch chrome", ctx()) == .openApp)
    check("'copy your answer' → copyLastAnswer", route("copy your answer", ctx()) == .copyLastAnswer)
    check("'copy that to my clipboard' → copyLastAnswer",
          route("copy that to my clipboard", ctx()) == .copyLastAnswer)
    check("'copy what you just said' → copyLastAnswer",
          route("copy what you just said", ctx()) == .copyLastAnswer)
    check("plain 'copy this file' is NOT clipboard route",
          route("how do i copy this file", ctx()) != .copyLastAnswer)

    // --- "give text" (blue side-text answers) ---
    check("'give me X in text' → showText",
          route("give me martin luther king's birthday in text", ctx()) == .showText)
    check("'give text' → showText", route("give text", ctx()) == .showText)
    check("'show me the text' → showText", route("show me the text for that", ctx()) == .showText)
    check("'give me pi in text' works in text mode too",
          route("give me pi in text", ctx(vision: false)) == .showText)
    check("plain question is NOT showText", route("what's the capital of france", ctx()) == .text)

    // --- Web reach (the one internet-answering route) ---
    check("'what's the latest … online' → webReach",
          route("what's the latest on the mars mission online", ctx()) == .webReach)
    check("'look it up online' → webReach", route("look it up online for me", ctx()) == .webReach)
    check("'search the web and tell me' → webReach",
          route("search the web and tell me who won", ctx()) == .webReach)
    check("plain local question is NOT webReach", route("what's the capital of france", ctx()) == .text)
    check("'what's the weather' → webReach (needs live data)", route("what's the weather today", ctx()) == .webReach)
    check("'price of bitcoin' → webReach", route("what's the price of bitcoin", ctx()) == .webReach)
    check("'who won the' game → webReach", route("who won the lakers game", ctx()) == .webReach)
    check("general knowledge stays local, NOT webReach", route("explain how photosynthesis works", ctx()) == .text)
    check("'who is the current ceo of X' → webReach", route("who is the current ceo of twitter", ctx()) == .webReach)
    check("'who is the president' → webReach", route("who is the president right now", ctx()) == .webReach)
    check("'latest on the election' → webReach", route("what's the latest on the election", ctx()) == .webReach)
    check("'on my screen right now' stays screen (not webReach)", route("what is on my screen right now", ctx()) == .screen)
    check("extractResultURLs decodes ddg uddg redirects",
          WebReachTool.extractResultURLs(from: "x [a](https://duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FX) y").contains("https://en.wikipedia.org/wiki/X"))
    check("'open gmail' still → browserCommand (not webReach)", route("open gmail", ctx()) == .browserCommand)
    check("webReach fallback URL targets r.jina.ai", WebReachTool.fallbackSearchURL(for: "x")?.host == "r.jina.ai")
    check("freshness bias appends current year when none present",
          WebReachTool.freshnessBiasedQuery("who won the super bowl", now: Date(timeIntervalSince1970: 1_780_000_000)).hasSuffix("2026"))
    check("freshness bias leaves an explicit year alone",
          WebReachTool.freshnessBiasedQuery("who won the 2014 super bowl") == "who won the 2014 super bowl")
    check("webReach search URL targets r.jina.ai", WebReachTool.searchURL(for: "nobel prize")?.host == "r.jina.ai")
    check("webReach read URL targets r.jina.ai", WebReachTool.readURL(for: "example.com")?.host == "r.jina.ai")

    // --- Computer use: timer routing + parsing ---
    check("'set a timer for 4 minutes' → setTimer", route("set a timer for 4 minutes", ctx()) == .setTimer)
    check("'timer for 30 seconds' → setTimer", route("set a timer for 30 seconds", ctx()) == .setTimer)
    check("'two minute timer' → setTimer", route("give me a two minute timer", ctx()) == .setTimer)
    check("plain question is NOT a timer", route("what's the capital of france", ctx()) != .setTimer)
    check("timer parse: 4 minutes = 240s", ComputerActionPlanner.timerRequest(from: "set a timer for 4 minutes")?.seconds == 240)
    check("timer parse: 30 seconds = 30s", ComputerActionPlanner.timerRequest(from: "timer for 30 seconds")?.seconds == 30)
    check("timer parse: word 'two minutes' = 120s", ComputerActionPlanner.timerRequest(from: "a two minute timer")?.seconds == 120)
    check("timer parse: '1 hour 30 minutes' = 5400s", ComputerActionPlanner.timerRequest(from: "set a timer for 1 hour 30 minutes")?.seconds == 5400)
    check("timer parse: no duration → nil", ComputerActionPlanner.timerRequest(from: "set a timer") == nil)

    // --- Computer use: Spotify routing + parsing ---
    check("'play despacito on spotify' → spotify", route("play despacito on spotify", ctx()) == .spotify)
    check("'pause spotify' → spotify", route("pause spotify", ctx()) == .spotify)
    check("'next song on spotify' → spotify", route("next song on spotify", ctx()) == .spotify)
    check("'open spotify' opens the desktop app (not web)", route("open spotify", ctx()) == .openApp)
    check("'launch spotify' opens the app, not spotify-control", route("launch spotify", ctx()) == .openApp)
    check("plain 'play' (no spotify) is NOT spotify", route("play", ctx()) != .spotify)
    check("spotify parse: play query", ComputerActionPlanner.spotifyAction(from: "play bohemian rhapsody on spotify") == .playQuery("bohemian rhapsody"))
    check("spotify parse: pause", ComputerActionPlanner.spotifyAction(from: "pause spotify") == .pause)
    check("spotify parse: next", ComputerActionPlanner.spotifyAction(from: "skip this song on spotify") == .next)
    check("spotify parse: bare play", ComputerActionPlanner.spotifyAction(from: "play spotify") == .play)

    // --- Computer use: explicit browser search ("on my computer" / "in google") ---
    check("'search cats on my computer' → browserCommand", route("search cats on my computer", ctx()) == .browserCommand)
    check("'search cats in google' → browserCommand", route("search cats in google", ctx()) == .browserCommand)
    check("'google the weather' → browserCommand", route("google the weather", ctx()) == .browserCommand)
    check("computer search query strips 'on my computer'", ComputerActionPlanner.computerSearchQuery(from: "search cats on my computer") == "cats")
    check("computer search query strips 'in google'", ComputerActionPlanner.computerSearchQuery(from: "search the eiffel tower in google") == "the eiffel tower")
    check("bare 'search cats' is NOT a computer search", ComputerActionPlanner.computerSearchQuery(from: "search cats") == nil)

    // --- Prompt integrity (describe vs point vs honest concise) ---
    check("conciseText forbids made-up facts", LocalPrompts.conciseText.contains("never make up"))
    check("screenDescribe has NO pointing instruction",
          !LocalPrompts.screenDescribe(imageWidthInPixels: 100, imageHeightInPixels: 100).contains("[POINT"))
    check("screenVoiceResponse keeps pointing instruction",
          LocalPrompts.screenVoiceResponse(imageWidthInPixels: 100, imageHeightInPixels: 100).contains("[POINT"))
    check("screenPointResponse demands a tag every time",
          LocalPrompts.screenPointResponse(imageWidthInPixels: 100, imageHeightInPixels: 100).contains("[POINT:x,y:label]")
          && LocalPrompts.screenPointResponse(imageWidthInPixels: 100, imageHeightInPixels: 100).lowercased().contains("must always"))
    check("isLikelyGroundingCapable: moondream is not", !LocalModels.isLikelyGroundingCapable("moondream"))
    check("isLikelyGroundingCapable: qwen2.5vl is", LocalModels.isLikelyGroundingCapable("qwen2.5vl:3b"))
    check("'open gmail' still → browserCommand", route("open gmail", ctx()) == .browserCommand)
    check("'open a new tab and go to gmail' still → browserCommand",
          route("open a new tab and go to gmail", ctx()) == .browserCommand)

    // --- App name resolution (matching installed apps) ---
    let installedSample = ["notes", "google chrome", "visual studio code", "activity monitor",
                           "system settings", "messages", "xcode", "spotify"]
    check("resolve 'notes' → notes",
          AppCommandPlanner.resolveAppName("notes", installedNames: installedSample) == "notes")
    check("resolve alias 'chrome' → google chrome",
          AppCommandPlanner.resolveAppName("chrome", installedNames: installedSample) == "google chrome")
    check("resolve alias 'vs code' → visual studio code",
          AppCommandPlanner.resolveAppName("vs code", installedNames: installedSample) == "visual studio code")
    check("resolve alias 'settings' → system settings",
          AppCommandPlanner.resolveAppName("settings", installedNames: installedSample) == "system settings")
    check("resolve 'activity monitor' → activity monitor",
          AppCommandPlanner.resolveAppName("activity monitor", installedNames: installedSample) == "activity monitor")
    check("resolve missing app → nil",
          AppCommandPlanner.resolveAppName("photoshop", installedNames: installedSample) == nil)
    check("'photoshop' does NOT false-match 'photos'",
          AppCommandPlanner.resolveAppName("photoshop", installedNames: ["photos", "notes"]) == nil)
    check("'calc' → calculator (prefix)",
          AppCommandPlanner.resolveAppName("calc", installedNames: ["calculator", "calendar"]) == "calculator")
    check("'monitor' → activity monitor (whole word)",
          AppCommandPlanner.resolveAppName("monitor", installedNames: ["activity monitor", "notes"]) == "activity monitor")

    // --- Model install matching (tag normalization) ---
    check("exact tag matches",
          OllamaClient.modelInstalled("llama3.2:3b", among: ["llama3.2:3b", "qwen2.5vl:3b"]))
    check("tagless wanted matches :latest",
          OllamaClient.modelInstalled("llama3.2", among: ["llama3.2:latest"]))
    check("different tag does NOT match",
          !OllamaClient.modelInstalled("llama3.2:3b", among: ["llama3.2:1b"]))
    check("missing model not matched",
          !OllamaClient.modelInstalled("mistral:7b", among: ["llama3.2:3b"]))

    // --- HardwareAdvisor (recommendation is a pure function of the profile) ---
    func profile(total: Double, avail: Double) -> HardwareProfile {
        HardwareProfile(totalRAMGB: total, availableRAMGB: avail, physicalCores: 8, isAppleSilicon: true)
    }
    let rec16 = HardwareAdvisor.recommend(for: profile(total: 16, avail: 6.3))
    check("16GB → llama3.2:3b text", rec16.chatModel == "llama3.2:3b")
    check("16GB → moondream vision", rec16.visionModel == "moondream")
    check("16GB → qwen2.5vl grounding", rec16.groundingModel == "qwen2.5vl:3b")
    check("16GB keeps text+vision resident",
          rec16.residentModels.contains("llama3.2:3b") && rec16.residentModels.contains("moondream"))
    check("16GB does NOT keep grounding resident (tight)", !rec16.keepsGroundingResident)
    let rec32 = HardwareAdvisor.recommend(for: profile(total: 32, avail: 24))
    check("32GB → stronger coder text", rec32.chatModel == "qwen2.5-coder:7b")
    check("32GB → qwen3-vl grounding", rec32.groundingModel == "qwen3-vl:8b")
    check("32GB keeps grounding resident", rec32.keepsGroundingResident)
    let rec4 = HardwareAdvisor.recommend(for: profile(total: 4, avail: 2))
    check("4GB → tiny 1b text", rec4.chatModel == "llama3.2:1b")
    check("fits(): moondream alone fits 6GB", HardwareAdvisor.fits(["moondream"], inBudgetGB: 6))
    check("fits(): three big models don't fit 6GB",
          !HardwareAdvisor.fits(["llama3.2:3b", "moondream", "qwen2.5vl:3b"], inBudgetGB: 6))
    check("catalog: moondream known", ModelCatalog.model(named: "moondream") != nil)
    check("catalog: unknown model → safe residentGB estimate", ModelCatalog.residentGB(of: "mystery:99b") == 4.0)

    // --- AutotuneBridge: tolerant model-id parsing ---
    let sample = "Recommended (balanced): qwen2.5-coder:7b — MMLU 84%, fits in 6.2 GB. Runs at 9:30."
    check("autotune parse: picks model id, not the time",
          AutotuneBridge.parseRecommendedModel(from: sample, installed: []) == "qwen2.5-coder:7b")
    check("autotune parse: nil when no model id",
          AutotuneBridge.parseRecommendedModel(from: "no models here, just text", installed: []) == nil)

    // --- Ollama pull progress parsing ---
    let (pp1, pe1) = OllamaClient.parsePullLine("{\"status\":\"downloading\",\"completed\":50,\"total\":100}")
    check("pull parse: 50% fraction", pp1?.fraction == 0.5 && pe1 == nil)
    let (pp2, _) = OllamaClient.parsePullLine("{\"status\":\"success\"}")
    check("pull parse: success → complete", pp2?.isComplete == true)
    let (pp3, pe3) = OllamaClient.parsePullLine("{\"error\":\"model 'nope' not found\"}")
    check("pull parse: error surfaced", pp3 == nil && pe3 == "model 'nope' not found")
    let (pp4, _) = OllamaClient.parsePullLine("   ")
    check("pull parse: blank line ignored", pp4 == nil)

    // --- Ink in/out: mapping, strokes, summary, image, accessibility, shape tags ---
    let inkMap = ScreenMapping(displayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                               displayWidthInPoints: 1920, displayHeightInPoints: 1080,
                               screenshotWidthInPixels: 1280, screenshotHeightInPixels: 720)
    check("mapping: forward top-left pixel → AppKit top-left of a left monitor",
          inkMap.globalPoint(forImagePoint: .zero) == CGPoint(x: -1920, y: 1080))
    let inkRound = inkMap.imagePoint(forGlobalPoint: inkMap.globalPoint(forImagePoint: CGPoint(x: 321, y: 123)))
    check("mapping: image → global → image round trip",
          abs(inkRound.x - 321) < 1e-9 && abs(inkRound.y - 123) < 1e-9)
    check("mapping: overlay point → pixel",
          inkMap.imagePoint(forOverlayPoint: CGPoint(x: 960, y: 540)) == CGPoint(x: 640, y: 360))

    func inkCircle(_ degrees: Double) -> [InkSample] {
        (0...48).map { step in
            let angle = degrees * Double.pi / 180 * Double(step) / 48
            return InkSample(point: CGPoint(x: 500 + 80 * cos(angle), y: 400 + 80 * sin(angle)), time: Double(step) * 0.016)
        }
    }
    check("ink: full circle classified as circle", InkStroke(samples: inkCircle(360)).marks().map(\.kind) == [.circle])
    check("ink: half circle is not a circle", InkStroke(samples: inkCircle(180)).marks().first?.kind != .circle)
    let inkLine = (0...20).map { InkSample(point: CGPoint(x: 100 + Double($0) * 15, y: 200), time: Double($0) * 0.016) }
    check("ink: straight run classified as line", InkStroke(samples: inkLine).marks().map(\.kind) == [.line])
    let inkJiggle = (0..<6).map { InkSample(point: CGPoint(x: 300 + Double($0 % 2) * 3, y: 300), time: Double($0) * 0.02) }
    check("ink: jiggle is rejected", InkStroke(samples: inkJiggle).analyze().isEmpty)
    let inkHeld = inkLine + (1...20).map { InkSample(point: CGPoint(x: 400 + Double($0 % 2), y: 200), time: 0.4 + Double($0) * 0.05) }
    check("ink: a 1 s hold is a dwell", InkStroke(samples: inkHeld).dwells().count == 1)
    check("ink: region grid names",
          InkRegion.name(for: CGPoint(x: 10, y: 10), in: CGSize(width: 900, height: 600)) == "top left"
          && InkRegion.name(for: CGPoint(x: 450, y: 300), in: CGSize(width: 900, height: 600)) == "center"
          && InkRegion.name(for: CGPoint(x: 890, y: 590), in: CGSize(width: 900, height: 600)) == "bottom right")
    let inkSummary = GestureSummary.describe(InkStroke(samples: inkCircle(360)).analyze(), screenSize: CGSize(width: 1200, height: 900))
    check("gesture summary: one circle in the center",
          inkSummary == "The user drew 1 mark while speaking: circled an area in the center.")

    if let base = inkJPEG(width: 200, height: 120),
       let inked = InkImage.compositeInk(jpegData: base,
                                         strokesInImagePixels: [[CGPoint(x: 20, y: 60), CGPoint(x: 180, y: 60)]],
                                         style: InkPalette.resolve(preset: .standard, increaseContrast: false,
                                                                   differentiateWithoutColor: false, reduceMotion: false).userInk) {
        let inkedImage = CGImageSourceCreateWithData(inked as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        check("ink image: composite keeps the pixel size", inkedImage?.width == 200 && inkedImage?.height == 120)
        check("ink image: crop returns a rect inside the image",
              InkImage.cropAround(jpegData: base, rectInImagePixels: CGRect(x: 90, y: 50, width: 10, height: 10),
                                  padding: 0.2, minSide: 64, maxLongEdge: 512)?.rectInImagePixels
                == CGRect(x: 63, y: 23, width: 64, height: 64))
    } else {
        check("ink image: synthetic JPEG composite worked", false)
    }
    check("ink image: crop rect clamps near a corner",
          InkImage.cropRect(forInkBounds: CGRect(x: 0, y: 0, width: 10, height: 10),
                            imageSize: CGSize(width: 1152, height: 748), padding: 0.2, minSide: 320)
            == CGRect(x: 0, y: 0, width: 320, height: 320))

    let axText = AccessibilitySummary.summarize([
        AccessibilityElementRecord(role: "AXTextField", title: "Password", value: "hunter2", isSecure: true,
                                   frame: CGRect(x: 0, y: 0, width: 50, height: 20)),
        AccessibilityElementRecord(role: "AXButton", title: "Save", frame: CGRect(x: 0, y: 40, width: 50, height: 20)),
        AccessibilityElementRecord(role: "AXButton", title: "Save", frame: CGRect(x: 90, y: 40, width: 50, height: 20)),
    ])
    check("accessibility: secure field dropped, duplicates merged",
          !axText.contains("hunter2") && !axText.contains("Password") && axText.components(separatedBy: "\"Save\"").count == 2)

    let walkLeaf = (0..<500).map { index in (index, CGRect(x: 100, y: 100, width: 5, height: 5)) }
    let walkResult = AccessibilityTreeWalk.collect(roots: [-1], inkRect: CGRect(x: 90, y: 90, width: 30, height: 30),
                                                   frame: { $0 < 0 ? CGRect(x: 0, y: 0, width: 800, height: 600) : walkLeaf[$0].1 },
                                                   children: { $0 < 0 ? Array(0..<500) : [] })
    check("accessibility walk: bounded to 200 nodes, keeps only frames that meet the ink",
          walkResult.visited == 200 && walkResult.stoppedEarly
          && !AccessibilityTreeWalk.frameOverlaps(CGRect(x: 300, y: 300, width: 10, height: 10), inkRect: CGRect(x: 90, y: 90, width: 30, height: 30)))
    check("accessibility link: finds an address up to 3 levels, never more",
          AccessibilityLinkResolver.resolve(from: 0, parent: { $0 < 5 ? $0 + 1 : nil }, url: { $0 == 3 ? "https://x.test" : nil }, label: { _ in nil }).url == "https://x.test"
          && AccessibilityLinkResolver.resolve(from: 0, parent: { $0 + 1 }, url: { $0 == 4 ? "https://x.test" : nil }, label: { _ in nil }).url == nil)
    check("ink dwell: report and split thresholds are 0.35 s and 0.6 s",
          InkStroke.dwellReportDuration == 0.35 && InkStroke.markSplitDuration == 0.6)

    let shapeResult = ShapeTagParser.parse(from: "[SHAPE:circle:500,400;560,400:save:screen2] That is the save button. [HIGHLIGHT:1,2,30,40:form] [POINT:7,8:x]")
    check("shape tag: circle parsed with label and screen",
          shapeResult.shapes.first?.kind == .circle && shapeResult.shapes.first?.label == "save"
          && shapeResult.shapes.first?.screenNumber == 2)
    check("shape tag: highlight parsed", shapeResult.highlights.first?.rect == CGRect(x: 1, y: 2, width: 29, height: 38))
    check("shape tag: all tags stripped from speech", shapeResult.spokenText == "That is the save button.")
    check("shape tag: wrong point count is dropped", ShapeTagParser.parseTag("[SHAPE:line:1,2;3,4;5,6:x]") == nil)
    check("shape tag: curve needs 3 to 16 points", ShapeTagParser.parseTag("[SHAPE:curve:1,2;3,4:x]") == nil
          && ShapeTagParser.parseTag("[SHAPE:curve:1,2;3,4;5,6:x]") != nil)
    let shapeDetector = StreamingShapeDetector()
    check("shape detector: silent until the tag closes",
          shapeDetector.feed(accumulated: "look [SHAPE:line:1,2;3,4:a").isEmpty)
    check("shape detector: fires once on close",
          shapeDetector.feed(accumulated: "look [SHAPE:line:1,2;3,4:a]").count == 1
          && shapeDetector.feed(accumulated: "look [SHAPE:line:1,2;3,4:a] more").isEmpty)
    check("segmenter: tag-first line speaks the sentence",
          SpokenTextSegmenter.speakablePrefix("[SHAPE:circle:1,2;3,4:x] That is the save button.") == "That is the save button.")
    check("segmenter: holds back an unclosed trailing fragment",
          SpokenTextSegmenter.speakablePrefix("it is here. [SHAPE:circle:1,") == "it is here. ")
    check("segmenter: skips mid-text tags",
          SpokenTextSegmenter.speakablePrefix("a [POINT:1,2:x] b") == "a b")
    check("pointing tag: spoken text drops SHAPE and HIGHLIGHT",
          PointingTagParser.parse(from: "ok [SHAPE:line:1,2;3,4] [HIGHLIGHT:1,2,3,4] [POINT:5,6:x]").spokenText == "ok")

    check("pointing label: trimmed and short passes", PointingLabel.bubbleText(from: "  save  button ") == "save button")
    check("pointing label: none, empty and long are ignored",
          PointingLabel.bubbleText(from: "none") == nil && PointingLabel.bubbleText(from: "") == nil
          && PointingLabel.bubbleText(from: "the small gear shaped settings control") == nil)

    let paletteDefault = InkPalette.resolve(preset: .standard, increaseContrast: false,
                                            differentiateWithoutColor: false, reduceMotion: false)
    let paletteContrast = InkPalette.resolve(preset: .standard, increaseContrast: true,
                                             differentiateWithoutColor: true, reduceMotion: true, pointsToPixelsScale: 0.5)
    check("ink palette: default user ink is white casing, dark casing, yellow core",
          paletteDefault.userInk.layers.map(\.width) == [10, 7, 4]
          && paletteDefault.userInk.layers.map(\.alpha) == [1, 1, 1]
          && abs(paletteDefault.userInk.layers[2].red - 240.0 / 255) < 1e-9)
    check("ink palette: increase contrast widens, scales with pixels, dashes assistant, shortens the fade",
          paletteContrast.userInk.layers.map(\.width) == [6.5, 4.5, 2.5]
          && paletteContrast.assistantDashed && paletteContrast.fade == InkFadeTimings(hold: 1.5, fade: 0.25))
    check("ink palette: high visibility is dashed whatever the flags",
          InkPalette.resolve(preset: .highVisibility, increaseContrast: false, differentiateWithoutColor: false,
                             reduceMotion: false).assistantDashed)

    // --- Ink to the model: routing, grid, turn analysis, prompt, timer ---
    func inkRoute(_ s: String, ink: Bool = true, vision: Bool = true) -> ConversationRoute {
        InkRouting.route(transcript: s, context: ctx(vision: vision), hasUsableInk: ink)
    }
    check("ink route: a question with ink is a describe turn", inkRoute("what is this") == .screen)
    check("ink route: ink beats an app keyword", inkRoute("open youtube") == .screen)
    check("ink route: pointing words still point", inkRoute("where do i click to save") == .screenPoint)
    check("ink route: click words still click", inkRoute("click the button i circled") == .screenClick)
    check("ink route: no ink leaves the router alone", inkRoute("open youtube", ink: false) == route("open youtube", ctx()))
    check("ink route: no vision, no ink route", inkRoute("what is this", vision: false) == route("what is this", ctx(vision: false)))

    let inkGrid = InkAccessibilityGrid.probePoints(in: CGRect(x: 0, y: 0, width: 60, height: 120),
                                                   extraPoints: [CGPoint(x: 7, y: 8)])
    check("ink grid: 6x6 cell centres plus the extras",
          inkGrid.count == 37 && inkGrid[0] == CGPoint(x: 5, y: 10) && inkGrid.last == CGPoint(x: 7, y: 8))

    let inkAbove = ScreenMapping(displayFrame: CGRect(x: 0, y: 982, width: 1512, height: 982),
                                 displayWidthInPoints: 1512, displayHeightInPoints: 982,
                                 screenshotWidthInPixels: 1152, screenshotHeightInPixels: 748)
    check("mapping: CG point for a display above the primary is negative",
          inkAbove.cgGlobalPoint(forDisplayLocalPoint: .zero, primaryScreenHeight: 982) == CGPoint(x: 0, y: -982))

    let inkTurnMap = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 600),
                                   displayWidthInPoints: 1000, displayHeightInPoints: 600,
                                   screenshotWidthInPixels: 500, screenshotHeightInPixels: 300)
    let inkRing = (0...48).map { step -> InkSample in
        let angle = 2 * Double.pi * Double(step) / 48
        return InkSample(point: CGPoint(x: 400 + 80 * cos(angle), y: 300 + 80 * sin(angle)), time: Double(step) * 0.016)
    }
    if let inkTurn = InkTurn.analyze(globalSamples: inkRing, mapping: inkTurnMap) {
        check("ink turn: circle worded and mapped to pixels",
              inkTurn.gestureSummary == "The user drew 1 mark while speaking: circled an area in the center."
              && abs(inkTurn.boundsInImagePixels.midX - 200) < 1 && abs(inkTurn.boundsInImagePixels.midY - 150) < 1)
    } else {
        check("ink turn: circle analysed", false)
    }
    check("ink turn: a jiggle gives no ink",
          InkTurn.analyze(globalSamples: (0..<6).map { InkSample(point: CGPoint(x: 300 + Double($0 % 2) * 3, y: 300), time: Double($0) * 0.02) },
                          mapping: inkTurnMap) == nil)

    let inkPrompt = LocalPrompts.inkAddendum(gestureSummary: "The user drew 1 mark while speaking: circled an area in the center.",
                                             markerColourName: "yellow", hasCloseUp: true,
                                             accessibilityBlock: "Elements inside the circled area, in reading order:\n- button \"Save\"")
    check("ink prompt: marker, summary, close-up line and element block",
          inkPrompt.contains("a yellow marker") && inkPrompt.contains("circled an area in the center")
          && inkPrompt.contains("second image is a close-up") && inkPrompt.hasSuffix("- button \"Save\""))
    check("ink prompt: names and links are said to come from the app",
          inkPrompt.contains("read directly from the app itself"))
    check("ink prompt: no close-up line on a pointing turn",
          !LocalPrompts.inkAddendum(gestureSummary: "x", markerColourName: "red", hasCloseUp: false).contains("second image"))

    let inkTimer = TurnTimer()
    inkTimer.setInk(marks: 2, crop: true)
    inkTimer.mark(.inkReady)
    inkTimer.mark(.axReady)
    let inkTimerLine = inkTimer.snapshot(outcome: "completed").jsonLine()
    check("turn timer: ink counts and stages are recorded, keys stay allowed",
          inkTimerLine.contains("\"ink_marks\":2") && inkTimerLine.contains("\"ink_crop\":true")
          && inkTimerLine.contains("ink_ready") && inkTimerLine.contains("ax_ready")
          && TurnTimingRecord.allowedJSONKeys.isSuperset(of: ["ink_marks", "ink_crop"]))

    let axOverlay = AccessibilityWindowInfo(pid: 100, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800), layer: 1000)
    let axApp = AccessibilityWindowInfo(pid: 200, bounds: CGRect(x: 0, y: 0, width: 500, height: 800), layer: 0)
    check("ax target: our overlay is skipped, the app under it is picked",
          AccessibilityTargetApp.owningPid(windows: [axOverlay, axApp], at: CGPoint(x: 100, y: 100), excludingPid: 100) == 200)
    check("ax target: the frontmost app wins when it is not us, the window pick runs when it is",
          AccessibilityTargetApp.targetPid(frontmostPid: 250, windows: [axApp], at: CGPoint(x: 1, y: 1), ownPid: 100) == 250
          && AccessibilityTargetApp.targetPid(frontmostPid: 100, windows: [axOverlay, axApp], at: CGPoint(x: 1, y: 1), ownPid: 100) == 200)
    check("ax target: no window at the point gives nil",
          AccessibilityTargetApp.owningPid(windows: [axApp], at: CGPoint(x: 900, y: 700), excludingPid: 100) == nil)

    var markSchedule = SpeechMarkScheduler<String>()
    markSchedule.markClosed("m1", at: 0)
    let markClip1 = markSchedule.sentenceQueued()
    markSchedule.markClosed("m2", at: 0.2)
    let markClip2 = markSchedule.sentenceQueued()
    markSchedule.clipStarted(id: markClip1, at: 0.5)
    let markFirst = markSchedule.release(at: 0.5)
    markSchedule.markClosed("m3", at: 1.0)
    let markSecondEarly = markSchedule.release(at: 1.2)
    markSchedule.clipStarted(id: markClip2, audibleIn: 0.18, at: 2.0)
    check("speech marks: each tag binds to its own sentence and shows when that clip starts",
          markFirst == ["m1"] && markSecondEarly.isEmpty && markSchedule.release(at: 2.04) == ["m2"])
    check("speech marks: a tag with no sentence shows after 1.5 s, a cancel drops what waits",
          markSchedule.release(at: 2.49) == [] && markSchedule.release(at: 2.5) == ["m3"]
          && { var c = SpeechMarkScheduler<Int>(); c.markClosed(1, at: 0); return c.cancel() == 1 && c.release(at: 9).isEmpty }())

    let drawCtx = ConversationRouter.Context(visionModeSelected: true, screenAvailable: true,
                                             previousTurnUsedScreen: false, hasConversationHistory: false)
    func drawRoute(_ words: String, enabled: Bool = true) -> ConversationRoute {
        DrawingRouting.route(transcript: words, context: drawCtx, hasUsableInk: false, drawingEnabled: enabled)
    }
    check("draw route: circle, highlight and show-me-where draw when enabled",
          drawRoute("circle the save button") == .screenDraw && drawRoute("highlight the total") == .screenDraw
          && drawRoute("show me where the settings are") == .screenDraw)
    check("draw route: ordinary words do not trigger", !DrawingIntent.wantsDrawing("what is a bookmark")
          && !DrawingIntent.wantsDrawing("open the drawer") && !DrawingIntent.wantsDrawing("mark it as read"))
    check("draw route: a click command wins, an action route is kept",
          DrawingRouting.route(transcript: "click the button i circled", context: drawCtx, hasUsableInk: true, drawingEnabled: true) == .screenClick
          && drawRoute("set a timer for 4 minutes and mark it") == .setTimer)
    check("draw route: disabled changes nothing (highlight still points)",
          drawRoute("highlight the total", enabled: false) == .screenPoint
          && drawRoute("circle the save button", enabled: false)
              == InkRouting.route(transcript: "circle the save button", context: drawCtx, hasUsableInk: false))
    let drawPrompt = LocalPrompts.screenDrawResponse(imageWidthInPixels: 1152, imageHeightInPixels: 748)
    check("draw prompt: size, both tag forms, ring rule, spoken parity",
          drawPrompt.contains("1152x748") && drawPrompt.contains("[SHAPE:") && drawPrompt.contains("[HIGHLIGHT:")
          && drawPrompt.contains("just outside the thing") && drawPrompt.contains("say what the mark is on"))

    check("draw prompt: the circle grammar is two positions, never sizes",
          drawPrompt.contains("[SHAPE:circle:cx,cy;ex,ey:label]") && drawPrompt.contains("both pairs are positions, never sizes")
          && !drawPrompt.contains("rx,ry"))
    let pointDrawMap = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440), displayWidthInPoints: 2560,
                                     displayHeightInPoints: 1440, screenshotWidthInPixels: 1152, screenshotHeightInPixels: 648)
    func pointDrawShape(_ plan: PointDrawPlan) -> ShapeTag? {
        if case .shape(let tag) = plan.drawing { return tag } else { return nil }
    }
    let pointDrawCircle = PointThenDraw.plan(kind: .circle, pointInImagePixels: CGPoint(x: 400, y: 300), label: "save button",
                                             controlFrameInDisplayPoints: nil, mapping: pointDrawMap)
    check("point then draw: a circle is centred on the point with the default radius, sentence from the label",
          pointDrawShape(pointDrawCircle)?.kind == .circle
          && pointDrawShape(pointDrawCircle)?.points == [CGPoint(x: 400, y: 300), CGPoint(x: 430, y: 300)]
          && pointDrawShape(pointDrawCircle)?.label == "save button"
          && pointDrawCircle.spokenSentence == "that is the save button, circled.")
    let pointDrawArrow = PointThenDraw.plan(kind: .arrow, pointInImagePixels: CGPoint(x: 200, y: 300), label: nil,
                                            controlFrameInDisplayPoints: nil, mapping: pointDrawMap)
    check("point then draw: the arrow tail goes to the side with more room",
          pointDrawShape(pointDrawArrow)?.kind == .arrow
          && pointDrawShape(pointDrawArrow)?.points == [CGPoint(x: 290, y: 300), CGPoint(x: 200, y: 300)])
    check("point then draw: circle and arrow requests only, flag falls back to the shape tags",
          DrawingIntent.pointThenDrawKind("circle the save button", pointThenDrawEnabled: true) == .circle
          && DrawingIntent.pointThenDrawKind("draw an arrow to the gear", pointThenDrawEnabled: true) == .arrow
          && DrawingIntent.pointThenDrawKind("underline the title", pointThenDrawEnabled: true) == nil
          && DrawingIntent.pointThenDrawKind("circle the save button", pointThenDrawEnabled: false) == nil)
    let floorStyle = InkPalette.resolve(preset: .standard, increaseContrast: false, differentiateWithoutColor: false,
                                        reduceMotion: false, pointsToPixelsScale: 0.45).userInk
    check("ink floor: the model's copy has a core of at least 3 px at the external display scale",
          abs((floorStyle.withMinimumCoreWidth(InkTurn.minimumCoreWidthInImagePixels).layers.last?.width ?? 0) - 3) < 1e-9
          && abs((floorStyle.layers.last?.width ?? 0) - 1.8) < 1e-9)

    let markCircle = OverlayDrawing.shape(kind: .circle, points: [CGPoint(x: 300, y: 200), CGPoint(x: 340, y: 200)])
    let markGeometry = MarkGeometryBuilder.geometry(for: markCircle)
    check("mark geometry: a circle is two closed passes, deterministic",
          markGeometry.passes.count == 2 && markGeometry.passes.allSatisfy { $0.count == 1 && $0[0].isClosed }
          && markGeometry == MarkGeometryBuilder.geometry(for: markCircle))
    var markMaxGap = 0.0
    for (first, second) in zip(markGeometry.passes[0][0].points, markGeometry.passes[1][0].points) {
        markMaxGap = max(markMaxGap, Double(hypot(first.x - second.x, first.y - second.y)))
    }
    check("mark geometry: the second pass is within 1.5 pt of the first", markMaxGap <= MarkGeometryBuilder.maxPassOffset && markMaxGap > 0)
    let markArrow = MarkGeometryBuilder.arrowhead(tail: CGPoint(x: 0, y: 0), tip: CGPoint(x: 200, y: 0))
    check("mark geometry: the arrowhead sits on the tip, barbs trail back",
          markArrow[1] == CGPoint(x: 200, y: 0) && markArrow[0].x < 200 && markArrow[2].x < 200)
    let markCurve = MarkGeometryBuilder.catmullRom([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 40), CGPoint(x: 100, y: 0)], samplesPerSegment: 12)
    check("mark geometry: the curve passes through its points",
          markCurve.first == CGPoint(x: 0, y: 0) && markCurve.last == CGPoint(x: 100, y: 0)
          && abs(markCurve[12].x - 50) < 1e-9 && abs(markCurve[12].y - 40) < 1e-9)
    let markMap = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 500, height: 250), displayWidthInPoints: 500,
                                displayHeightInPoints: 250, screenshotWidthInPixels: 1000, screenshotHeightInPixels: 500)
    check("mark geometry: a tag maps from screenshot pixels to overlay points",
          ShapeTagParser.parseTag("[SHAPE:line:600,300;800,400]").map { MarkGeometryBuilder.overlayDrawing(from: $0, mapping: markMap) }
              == .shape(kind: .line, points: [CGPoint(x: 300, y: 150), CGPoint(x: 400, y: 200)]))
    let markTimer = TurnTimer()
    markTimer.mark(.firstMark)
    markTimer.setMarks(2)
    let markTimerLine = markTimer.snapshot(outcome: "completed").jsonLine()
    check("turn timer: first_mark stage and marks count, key stays allowed",
          markTimerLine.contains("first_mark") && markTimerLine.contains("\"marks\":2")
          && TurnTimingRecord.allowedJSONKeys.contains("marks"))

    check("model roles: grounding needs vision, defaults to the grounding model, others unchanged",
          ModelRole.grounding.requiredCapability == "vision" && ModelRole.grounding.defaultModel == LocalModels.defaultGroundingModel
          && ModelRole.chat.requiredCapability == "completion" && ModelRole.vision.defaultModel == LocalModels.defaultVisionModel)

    // --- Safety: inference is localhost-only (no cloud) ---
    check("default Ollama endpoint is localhost", LocalModels.defaultOllamaBaseURL.host == "127.0.0.1")
    check("OllamaClient talks only to localhost", OllamaClient().baseURL.host == "127.0.0.1")
    check("identity prompt states no-cloud", LocalPrompts.identity.contains("no cloud"))

    print(failures == 0 ? "\nALL PARSER + ROUTER + SEGMENTER + BROWSER + ADVISOR + AGENT TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Lists the models installed in the local Ollama and which LocalClicky role(s)
/// each can fill, so a user can see what they're allowed to pick. Also doubles as
/// a live check of the picker's data path (listInstalledModels + capabilities).
func runModelList() async {
    let client = OllamaClient()
    print("=== Installed Ollama models (LocalClicky model picker) ===")
    guard await client.isServerReachable() else {
        print("❌ Ollama not reachable on \(client.baseURL). Start it: ollama serve")
        exit(1)
    }
    guard let models = try? await client.listInstalledModels(), !models.isEmpty else {
        print("No models installed. Pull one, e.g.: ollama pull \(LocalModels.defaultVisionModel)")
        exit(1)
    }
    func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
    print("  " + pad("model", 26) + pad("size", 10) + "roles")
    for model in models {
        let caps = await client.capabilities(of: model.name)
        var roles: [String] = []
        if caps.contains("completion") { roles.append("text") }
        if caps.contains("vision") { roles.append("vision") }
        let roleText = roles.isEmpty ? "—" : roles.joined(separator: ", ")
        let isDefault = model.name == LocalModels.defaultChatModel || model.name == LocalModels.defaultVisionModel
        print("  " + pad(model.name, 26) + pad(model.sizeDescription, 10) + roleText + (isDefault ? "  (default)" : ""))
    }
    print("\nText role default:   \(LocalModels.defaultChatModel)")
    print("Vision role default: \(LocalModels.defaultVisionModel)")
}

/// Prints the native hardware profile + the advisor's model recommendation, plus
/// whether the optional autotune CLI is installed (the hybrid path).
func runAdvise() {
    let profile = HardwareAdvisor.detect()
    print("=== LocalClicky hardware advisor ===")
    print("Hardware: \(profile.summary)")
    print(String(format: "  total RAM: %.1f GB  ·  available now: %.1f GB", profile.totalRAMGB, profile.availableRAMGB))
    let rec = HardwareAdvisor.recommend(for: profile)
    print("\nRecommended for this machine:")
    print("  text:      \(rec.chatModel)")
    print("  vision:    \(rec.visionModel)")
    print("  grounding: \(rec.groundingModel)")
    print("  resident set (kept warm): \(rec.residentModels.joined(separator: ", "))")
    print("  grounding stays resident: \(rec.keepsGroundingResident)   keep_alive: \(rec.keepAlive)")
    print("  → \(rec.summary)")

    print("\nautotune CLI (hybrid):")
    let status = AutotuneBridge.quickStatus()
    if status.isInstalled {
        print("  installed at \(status.executablePath ?? "?")  \(status.version ?? "")")
        print("  (run `autotune recommend` for its full machine-measured suggestion)")
    } else {
        print("  not installed — using the native advisor (this is fine).")
    }
}

/// Drives the REAL answer pipeline against Ollama, mirroring CompanionManager's
/// route → model → prompt selection, so the whole brain is verified end-to-end:
/// text answers, "give text", Moondream screen-describe, qwen2.5vl pointing, and
/// the two-step screen joke. Exits non-zero if any critical check fails.
///   localbrain-harness --e2e <image.png>
func runE2E(imagePath: String) async {
    let client = OllamaClient()
    print("=== LocalClicky end-to-end pipeline (real models) ===")
    guard await client.isServerReachable() else {
        print("❌ Ollama not reachable. Start it: ollama serve"); exit(1)
    }
    guard let imageData = FileManager.default.contents(atPath: imagePath) else {
        print("❌ couldn't read image at \(imagePath)"); exit(1)
    }
    let (w, h) = pngPixelSize(path: imagePath) ?? (1920, 1080)
    let b64 = imageData.base64EncodedString()
    var failures = 0
    func line(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "✅ " : "❌ ") + name + (detail.isEmpty ? "" : "  — \(detail)"))
        if !ok { failures += 1 }
    }
    func ctx() -> ConversationRouter.Context {
        .init(visionModeSelected: true, screenAvailable: true, previousTurnUsedScreen: false, hasConversationHistory: false)
    }

    // 1) Plain text question → text model.
    let q1 = "what's the capital of france"
    let route1 = ConversationRouter.route(transcript: q1, context: ctx())
    let a1 = try? await client.streamChat(model: LocalModels.chatModel,
        messages: [.system(LocalPrompts.textVoiceResponse), .user(q1)],
        temperature: 0.2, maxTokens: 60, contextWindow: LocalModels.textContextWindow, onText: { _ in })
    line("text: route=.text + non-empty answer", route1 == .text && !(a1?.text.isEmpty ?? true), a1?.text ?? "nil")

    // 2) "give me X in text" → concise honest answer.
    let q2 = "give me the speed of light in text"
    let route2 = ConversationRouter.route(transcript: q2, context: ctx())
    let a2 = try? await client.streamChat(model: LocalModels.chatModel,
        messages: [.system(LocalPrompts.conciseText), .user(q2)],
        temperature: 0.1, maxTokens: 40, contextWindow: LocalModels.textContextWindow, onText: { _ in })
    line("give-text: route=.showText + non-empty answer", route2 == .showText && !(a2?.text.isEmpty ?? true), a2?.text ?? "nil")

    // 3) Screen describe → Moondream.
    let q3 = "what's on my screen"
    let route3 = ConversationRouter.route(transcript: q3, context: ctx())
    let a3 = try? await client.streamChat(model: LocalModels.visionModel,
        messages: [.system(LocalPrompts.screenDescribe(imageWidthInPixels: w, imageHeightInPixels: h)),
                   .user(q3, imagesBase64: [b64])],
        temperature: 0.3, maxTokens: 80, contextWindow: LocalModels.visionContextWindow, onText: { _ in })
    line("screen-describe: route=.screen + Moondream answer", route3 == .screen && !(a3?.text.isEmpty ?? true), a3?.text ?? "nil")

    // 4) Pointing → grounding model + the dedicated directive prompt must always
    //    return a WELL-FORMED tag: an in-bounds [POINT:x,y] when the target is
    //    visible, or a clean [POINT:none] when it isn't (both are valid pipeline
    //    outcomes — the failure mode we're catching is rambling with no tag). The
    //    target ("search box") is present on the test screenshot, so we expect an
    //    in-bounds point most of the time and retry a couple times for it.
    let q4 = "point at the search box"
    let route4 = ConversationRouter.route(transcript: q4, context: ctx())
    var pointDetail = "no tag"
    var wellFormed = false
    for _ in 0..<3 where !wellFormed {
        let a4 = try? await client.streamChat(model: LocalModels.groundingModel,
            messages: [.system(LocalPrompts.screenPointResponse(imageWidthInPixels: w, imageHeightInPixels: h)),
                       .user(q4, imagesBase64: [b64])],
            temperature: 0.2, maxTokens: 120, contextWindow: LocalModels.visionContextWindow, onText: { _ in })
        guard let parsed = a4.map({ PointingTagParser.parse(from: $0.text) }) else { continue }
        if let center = parsed.centerInImagePixels {
            pointDetail = "(\(Int(center.x)),\(Int(center.y)))"
            wellFormed = center.x >= 0 && center.x <= CGFloat(w) && center.y >= 0 && center.y <= CGFloat(h)
        } else if parsed.label == "none" {
            pointDetail = "none (no visible target)"
            wellFormed = true
        }
    }
    line("pointing: route=.screenPoint + well-formed tag (point or none)", route4 == .screenPoint && wellFormed, pointDetail)

    // 5) Two-step screen joke produces a line.
    let glance = try? await client.streamChat(model: LocalModels.visionModel,
        messages: [.system(LocalPrompts.screenGlanceSystem), .user(LocalPrompts.screenGlanceUser, imagesBase64: [b64])],
        temperature: 0.3, maxTokens: 50, contextWindow: LocalModels.visionContextWindow, onText: { _ in })
    var desc = glance?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if desc.count < 8 { desc = "their computer screen with a few things open" }
    let joke = try? await client.streamChat(model: LocalModels.chatModel,
        messages: [.system(LocalPrompts.screenJokeFromDescription),
                   .user("the user is looking at: \(desc). make the joke.")],
        temperature: 0.9, maxTokens: 50, contextWindow: LocalModels.textContextWindow, onText: { _ in })
    line("two-step screen joke produces a line", !(joke?.text.isEmpty ?? true), joke?.text ?? "nil")

    print(failures == 0 ? "\nE2E PASSED" : "\n\(failures) E2E CHECK(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Exercises the real web-reach pipeline live: fetch web results (Jina Reader),
/// then have the local text model synthesize a grounded spoken answer.
///   localbrain-harness --webreach "who won the 2024 nobel prize in physics"
func runWebReach(query: String) async {
    print("=== web reach: \"\(query)\" ===")
    print("fetching (https://r.jina.ai/ … the one opt-in cloud call)…")
    guard let results = await WebReachTool.search(query), !results.isEmpty else {
        print("❌ web fetch failed (no connection, or the reader was unreachable)"); exit(1)
    }
    print("✅ fetched \(results.count) chars of results")
    let client = OllamaClient()
    guard await client.isServerReachable() else { print("(Ollama not running — can't synthesize)"); exit(1) }
    let answer = try? await client.streamChat(
        model: LocalModels.chatModel,
        messages: [.system(LocalPrompts.webAnswer),
                   .user("question: \(query)\n\nfetched web content (source of truth):\n\(results)")],
        temperature: 0.0, maxTokens: 180, contextWindow: LocalModels.textContextWindow, onText: { _ in })
    print("\nanswer: \(answer?.text ?? "nil")")
    exit((answer?.text.isEmpty == false) ? 0 : 1)
}

func runHarness() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--selftest" { runSelfTest() }
    if arguments.first == "--advise" {
        runAdvise()
        return
    }
    if arguments.first == "--webreach" {
        guard arguments.count >= 2 else { print("usage: localbrain-harness --webreach \"<query>\""); exit(1) }
        await runWebReach(query: arguments[1])
        return
    }
    if arguments.first == "--e2e" {
        guard arguments.count >= 2 else { print("usage: localbrain-harness --e2e <image.png>"); exit(1) }
        await runE2E(imagePath: arguments[1])
        return
    }
    if arguments.first == "--models" {
        await runModelList()
        return
    }
    if arguments.first == "--benchmark" {
        let benchImage = arguments.count >= 2 ? arguments[1] : nil
        let iterations = arguments.count >= 3 ? (Int(arguments[2]) ?? 3) : 3
        await runBenchmark(imagePath: benchImage, iterations: iterations)
        return
    }
    if arguments.first == "--benchmark-suite" {
        guard arguments.count >= 2 else {
            print("usage: localbrain-harness --benchmark-suite <image.png> [iterations] [label]"); exit(1)
        }
        let iterations = arguments.count >= 3 ? (Int(arguments[2]) ?? 3) : 3
        let label = arguments.count >= 4 ? arguments[3] : "baseline"
        await runBenchmarkSuite(imagePath: arguments[1], iterations: iterations, label: label)
        return
    }
    let imagePath = arguments.first
    let customQuestion = arguments.count >= 2 ? arguments[1] : nil

    let client = OllamaClient()
    print("=== LocalClicky brain harness ===")

    // 1) Health
    guard await client.isServerReachable() else {
        print("❌ Ollama not reachable on \(client.baseURL). Start it with: ollama serve")
        exit(1)
    }
    print("✅ Ollama reachable at \(client.baseURL)")
    do {
        let missing = try await client.missingRequiredModels()
        if missing.isEmpty {
            print("✅ Required models installed: \(LocalModels.requiredModels.joined(separator: ", "))")
        } else {
            print("⚠️  Missing models: \(missing.joined(separator: ", "))")
        }
    } catch {
        print("⚠️  Could not list models: \(error.localizedDescription)")
    }

    // 2) Text chat (fast model)
    print("\n--- text chat (\(LocalModels.chatModel)) ---")
    do {
        let result = try await client.streamChat(
            model: LocalModels.chatModel,
            messages: [
                .system(LocalPrompts.textVoiceResponse),
                .user("what does git rebase actually do? keep it short."),
            ],
            temperature: 0.7, maxTokens: 200, onText: { _ in }
        )
        print("first token: \(fmt(result.firstTokenLatencySeconds)) | total: \(fmt(result.totalDurationSeconds)) | " +
              "\(result.tokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "n/a")")
        print("answer: \"\(result.text)\"")
    } catch {
        print("❌ text chat failed: \(error.localizedDescription)")
    }

    // 3) Vision Q&A + pointing
    guard let imagePath else {
        print("\n(no image given — skipping vision test. Pass an image path to test screen vision + pointing.)")
        return
    }
    guard let imageBase64 = loadImageBase64(imagePath) else {
        print("\n❌ couldn't read image at \(imagePath)")
        exit(1)
    }
    let (imageWidth, imageHeight) = pngPixelSize(path: imagePath) ?? (1280, 800)
    let question = customQuestion ?? "where do i click to start recording?"

    print("\n--- screen vision + pointing (\(LocalModels.visionModel)) on \(imagePath) [\(imageWidth)x\(imageHeight)] ---")
    print("question: \"\(question)\"")
    do {
        let result = try await client.streamChat(
            model: LocalModels.visionModel,
            messages: [
                .system(LocalPrompts.screenVoiceResponse(imageWidthInPixels: imageWidth, imageHeightInPixels: imageHeight)),
                .user(question, imagesBase64: [imageBase64]),
            ],
            temperature: 0.2, maxTokens: 200, onText: { _ in }
        )
        print("first token: \(fmt(result.firstTokenLatencySeconds)) | total: \(fmt(result.totalDurationSeconds))")
        print("raw model output: \"\(result.text)\"")
        let pointing = PointingTagParser.parse(from: result.text)
        print("spoken text: \"\(pointing.spokenText)\"")
        if let center = pointing.centerInImagePixels {
            print("➡️  POINT center: (\(Int(center.x)), \(Int(center.y)))  label: \(pointing.label ?? "—")" +
                  (pointing.screenNumber.map { "  screen: \($0)" } ?? ""))
        } else {
            print("➡️  no point (\(pointing.label ?? "none"))")
        }
    } catch {
        print("❌ vision test failed: \(error.localizedDescription)")
    }
}

await runHarness()

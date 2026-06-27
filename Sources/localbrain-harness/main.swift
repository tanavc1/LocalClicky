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
    _ = try? await client.streamChat(model: model, messages: [.system(LocalPrompts.textVoiceResponse), .user("hi")],
                                     temperature: 0.2, maxTokens: 8, onText: { _ in })
    for prompt in prompts {
        for _ in 0..<iterations {
            if let result = try? await client.streamChat(
                model: model,
                messages: [.system(LocalPrompts.textVoiceResponse), .user(prompt)],
                temperature: 0.2, maxTokens: 100, onText: { _ in }) {
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
    let systemPrompt = LocalPrompts.screenVoiceResponse(imageWidthInPixels: width, imageHeightInPixels: height)
    var samples = LatencySamples()
    var parsed = 0, inBounds = 0, attempts = 0
    // Warm-up (discarded).
    _ = try? await client.streamChat(model: model,
        messages: [.system(systemPrompt), .user(prompts.first ?? "what's on screen?", imagesBase64: [imageBase64])],
        temperature: 0.2, maxTokens: 160, onText: { _ in })
    for prompt in prompts {
        for _ in 0..<iterations {
            attempts += 1
            guard let result = try? await client.streamChat(
                model: model,
                messages: [.system(systemPrompt), .user(prompt, imagesBase64: [imageBase64])],
                temperature: 0.2, maxTokens: 160, onText: { _ in }) else { continue }
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
    check("screen 'where do i click' → screen", route("where do i click to start recording", ctx()) == .screen)
    check("screen 'this button' → screen", route("what does this button do", ctx()) == .screen)
    check("screen 'explain this error' → screen", route("explain this error", ctx()) == .screen)
    check("browser new tab → browserCommand", route("open a new tab and go to gmail", ctx()) == .browserCommand)
    check("browser gmail draft → browserCommand", route("go to my gmail and open up a draft", ctx()) == .browserCommand)
    check("browser works in text mode", route("open youtube", ctx(vision: false)) == .browserCommand)
    check("'open the file menu' is NOT browser", route("open the file menu", ctx()) == .screen)
    check("text mode never screens", route("what's on my screen", ctx(vision: false)) == .text)
    check("no screen permission falls back to text", route("where do i click", ctx(screen: false)) == .text)

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

    print(failures == 0 ? "\nALL PARSER + ROUTER + SEGMENTER + BROWSER + AGENT TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
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

func runHarness() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--selftest" { runSelfTest() }
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

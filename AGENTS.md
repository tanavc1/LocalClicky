# LocalClicky — Agent Instructions

<!-- Single source of truth for AI coding agents. CLAUDE.md is a symlink to this file. -->

## Overview

LocalClicky is a **fully local, no‑cloud** rebuild of Clicky: a macOS menu‑bar
companion that you talk to (push‑to‑talk, Control+Option), that sees your screen,
answers out loud, flies a blue cursor over to point at UI elements, and can open
and navigate your browser on command. Every inference runs on‑device —
speech‑to‑text (Apple Speech), reasoning (`llama3.2:3b`), screen *describe*
(`moondream`), screen *pointing/grounding* (`qwen2.5vl:3b`), and text‑to‑speech (a
neural **Piper** voice via the in‑process sherpa‑onnx runtime, with
`AVSpeechSynthesizer` as fallback). Fully‑local traffic is HTTP to a local Ollama
server on `127.0.0.1:11434`. There is **no telemetry, no auto‑updater, no account,
no API keys**. The single, opt‑in exception to "no cloud" is the web tool
(`WebReachTool`, route `.webReach`) — it only runs when the user explicitly asks to
look something up online, and is clearly flagged ("checking the web…").

## Architecture

- **Packaging**: a Swift Package (`Package.swift`), not an Xcode project. Builds
  with Command‑Line‑Tools `swift build`; `scripts/build-app.sh` wraps the binary
  into `LocalClicky.app`. Also opens directly in Xcode via `open Package.swift`.
- **Targets**: `LocalBrainKit` (no‑UI brain), `CSherpaOnnx` (C shim for the neural
  TTS runtime), `LocalClicky` (menu‑bar app), `localbrain-harness` (headless
  verification CLI), `LocalBrainKitTests`.
- **App type**: menu‑bar only (`LSUIElement=true`), not sandboxed (needs
  Accessibility + Screen Recording).
- **Inference**: local Ollama over HTTP (`Sources/LocalBrainKit/OllamaClient.swift`),
  a single consistent `num_ctx` (`LocalModels.defaultContextWindow`, 8192) on **every**
  call — text, vision, and warm‑up — so a screenshot + history can't overrun context
  *and* a model is never reloaded for a different context size (which matters when one
  model fills both roles). No MLX, no bundled LLM weights. (The neural TTS model/runtime
  *are* vendored in `vendor/sherpa/`.)
- **Models are user‑selectable**: the defaults (`llama3.2:3b` text, `qwen2.5vl:3b`
  vision) are tuned for 16 GB, but `ModelPreferences` + the panel's Models picker let a
  user point either role at any installed Ollama model. The vision role is validated via
  Ollama `/api/show` `capabilities` (must include `vision`); the text role must include
  `completion`. `OllamaClient` exposes `listInstalledModels()` + `capabilities(of:)`.
- **Routing**: `ConversationRouter` picks, per turn, among: `copyLastAnswer` /
  `showText` ("give me X in text" → concise blue side‑text) / `webReach` (opt‑in
  internet) / `openApp` / `browserCommand` (deterministic actions) vs `screen`
  (describe, Moondream) vs `screenPoint` (point, grounding model) vs `text`. A
  pointing question ("where do I click to open settings") is detected first so the
  app/browser launcher can't hijack it; it skips the VLM when the screen isn't needed.
- **Hardware/autotune**: `HardwareAdvisor` (native, always works) recommends per‑role
  models + the resident set for the machine's RAM; `AutotuneBridge` layers the
  `autotune` CLI's recommendation when installed. Per‑role `num_ctx` (text 4096 /
  vision 8192, reload‑safe) + keep‑alive keep the resident pair warm.
- **Downloads**: `OllamaClient.pullModel` streams `/api/pull`; `OllamaInstaller`
  detects/installs Ollama. The panel offers a Download‑Ollama button + a fit‑gated
  one‑click model download (progress → warm into RAM).
- **Voice**: neural Piper voice loaded once and held resident via the sherpa‑onnx C
  API (`PiperSpeechSynthesisClient`); spoken sentence‑by‑sentence as the answer
  streams (`SpokenTextSegmenter`). Apple voice is the automatic fallback.
- **Actions (all deterministic + structurally safe)**:
  - **Browser**: `BrowserCommandPlanner` (NL → known URLs) + `BrowserActionExecutor`
    (`NSWorkspace.open`). Navigation only — can't click/submit/send.
  - **App launch**: `AppCommandPlanner` (NL → app name, pure) + `LocalAppLauncher`
    (Launch Services + a scan of the Applications folders → opens an installed app).
  - **Clipboard**: "copy your answer" writes the last spoken answer to `NSPasteboard`.
- **Pointing**: on a `.screenPoint` turn the grounding model emits a tag —
  `[POINT:x,y:label]`, qwen2.5‑vl's attribute form `[POINT x="x" y="y"]`, or a bare
  box — which `PointingTagParser` reduces to a center point in screenshot‑pixel
  space; `CompanionManager` maps that to a global AppKit coordinate; `BlueCursorView`
  animates the cursor. Unchanged overlay. (Use a directive prompt — `screenPointResponse`
  — to keep the tag‑return rate high; the conversational prompt drops it ~half the time.)

See `docs/ARCHITECTURE.md` for the full pipeline.

## Key files

| File | Purpose |
|---|---|
| `Sources/LocalBrainKit/OllamaClient.swift` | Async client for local Ollama (`/api/chat` streaming + images, health checks, `num_ctx`, installed‑model listing + `/api/show` capabilities, tag‑normalized install matching). |
| `Sources/LocalBrainKit/PointingTag.swift` | Parses `[POINT:…]` / bounding boxes → a single center point. |
| `Sources/LocalBrainKit/LocalPrompts.swift` | System prompts (with LocalClicky identity) for screen / text / onboarding. |
| `Sources/LocalBrainKit/ConversationRouter.swift` | Per‑turn routing: clipboard / app‑launch / browser command vs screen vs text. |
| `Sources/LocalBrainKit/SpokenTextSegmenter.swift` | Splits a streaming answer into speakable sentences (skips the `[POINT]` tag). |
| `Sources/LocalBrainKit/BrowserCommandPlanner.swift` | Maps a spoken command → concrete browser URLs (known‑site table, Gmail compose). |
| `Sources/LocalBrainKit/AppCommandPlanner.swift` | Pure NL → app‑name extraction + deterministic install‑name matching (used by the launcher and unit‑tested). |
| `Sources/LocalBrainKit/LocalModels.swift` | Default model names (text/vision/grounding), `ModelRole`, per‑role context windows, `isLikelyGroundingCapable`, Ollama endpoint. |
| `Sources/LocalBrainKit/HardwareAdvisor.swift` | RAM/CPU detection + curated model catalog + per‑machine recommendation + resident‑set decision. Pure, unit‑tested. |
| `Sources/LocalBrainKit/AutotuneBridge.swift` | Detects + (best‑effort) parses the optional `autotune` CLI to enrich the recommendation. |
| `Sources/LocalBrainKit/WebReachTool.swift` | The one opt‑in cloud call: web read + search via Jina Reader (`r.jina.ai`). |
| `Sources/LocalClicky/System/OllamaInstaller.swift` | Detects/one‑click‑installs Ollama (download + unzip + launch, browser fallback). |
| `Sources/LocalClicky/App/CompanionManager.swift` | Central state machine; answer pipeline + actions (browser/app/clipboard/give‑text/web‑reach) + model selection/downloads + advisor + blue side‑text (intro/joke) + streaming TTS + warm‑up. |
| `Sources/LocalClicky/App/LocalClickyApp.swift` | Menu‑bar app entry point. |
| `Sources/LocalClicky/Actions/LocalAppLauncher.swift` | Resolves a spoken app name to an installed app (Launch Services + Applications scan) and opens it. |
| `Sources/LocalClicky/Local/ModelPreferences.swift` | Persists the user's chat/vision model choices (defaults baked in). |
| `Sources/LocalClicky/Local/PiperSpeechSynthesisClient.swift` | Neural Piper TTS via sherpa‑onnx C API (in‑process, resident model). |
| `Sources/LocalClicky/Local/SpeechSynthesizing.swift` | TTS protocol + coordinator (Piper, Apple fallback) + streaming progress. |
| `Sources/LocalClicky/Local/AppleSpeechSynthesisClient.swift` | Fallback on‑device TTS. |
| `Sources/LocalClicky/Browser/BrowserActionExecutor.swift` | Opens planned URLs in the default browser (navigation only). |
| `Sources/LocalClicky/Voice/*` | Push‑to‑talk + Apple Speech STT pipeline. |
| `Sources/LocalClicky/Overlay/OverlayWindow.swift` | Blue cursor overlay (the signature feature). |
| `Sources/LocalClicky/Panel/*` | Menu‑bar panel UI. |
| `Sources/LocalClicky/Capture/CompanionScreenCaptureUtility.swift` | ScreenCaptureKit screenshots. |
| `Sources/localbrain-harness/main.swift` | Headless end‑to‑end verification CLI. |

## Build & verify

```bash
scripts/bootstrap-ollama.sh        # ensure Ollama + models
scripts/fetch-tts.sh               # vendor the neural TTS runtime + Piper voice (once)
swift build                        # compile everything (CLT, no Xcode)
swift run localbrain-harness --selftest          # ~90 checks: parser + router + advisor + prompts + safety
swift run localbrain-harness --advise            # hardware profile + recommended models (+ autotune if present)
swift run localbrain-harness --models            # installed Ollama models + which role each can fill
swift run localbrain-harness --e2e shot.png      # full pipeline vs real models (text/describe/point/joke)
swift run localbrain-harness --webreach "latest mars news"      # the opt‑in web tool, end‑to‑end
swift run localbrain-harness --benchmark-suite shot.png 3 after # before/after report → docs/benchmarks/
scripts/build-app.sh && scripts/package-dmg.sh   # produce .app + DMG
```

Do **not** run `swift test` on a Command‑Line‑Tools‑only machine — XCTest ships
with full Xcode. Use `localbrain-harness --selftest` instead, or run the tests in
Xcode.

## Conventions

- Clear, specific, longer names over clever/short ones. Comments explain "why".
- All UI state on `@MainActor`; async/await throughout.
- **No cloud.** Do not add any network call to a non‑localhost host, any
  telemetry/analytics, or any API key. If a feature seems to need the cloud, find
  the local equivalent (Ollama model, Apple framework, vendored model) instead. The
  neural voice runs fully on‑device: the sherpa‑onnx runtime + Piper voice are
  vendored in `vendor/sherpa/` and linked in‑process — no network at speak time.
- Keep the blue‑cursor overlay's published contract intact:
  `detectedElementScreenLocation` / `detectedElementDisplayFrame` /
  `detectedElementBubbleText`.

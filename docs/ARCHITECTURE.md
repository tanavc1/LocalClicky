# LocalClicky architecture

LocalClicky keeps the original Clicky's menu‑bar UX and blue‑cursor overlay, and
replaces every cloud call with an on‑device equivalent. The only network traffic
is HTTP to a local Ollama server on `127.0.0.1:11434`.

## Packages / targets

| Target | Kind | Role |
|---|---|---|
| `LocalBrainKit` | library | The no‑UI "brain": Ollama client, `[POINT]` parser, prompts, model config, conversation router, spoken‑text segmenter, browser‑command planner. Pure logic, unit‑testable, no AppKit. |
| `CSherpaOnnx` | C target | Thin module exposing the sherpa‑onnx C API (neural TTS) to Swift. Implementations come from the vendored dylib the app links. |
| `LocalClicky` | executable (app) | The menu‑bar SwiftUI/AppKit app: overlay, panel, capture, push‑to‑talk, neural voice, browser executor, `CompanionManager`. |
| `localbrain-harness` | executable (CLI) | Runs the full local pipeline against the real models, headless, for verification. |
| `LocalBrainKitTests` | tests | Pointing‑parser unit tests (XCTest; needs Xcode to run, or use `--selftest`). |

## The answer pipeline

1. **Push‑to‑talk** — a listen‑only `CGEvent` tap detects Control+Option globally
   (`GlobalPushToTalkShortcutMonitor`), unchanged from the original.
2. **Speech‑to‑text** — `BuddyDictationManager` captures mic audio via
   `AVAudioEngine` and streams it to `AppleSpeechTranscriptionProvider`, which uses
   `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. No cloud STT.
3. **Screenshot** — on release, `CompanionScreenCaptureUtility` captures the cursor
   screen with ScreenCaptureKit (≤1280 px JPEG), excluding LocalClicky's own
   windows. The screenshot's pixel size defines the model's coordinate space.
4. **Routing** — `ConversationRouter` decides per turn whether this needs the
   screen, is a self‑contained/follow‑up question, or is a browser command. This is
   what makes follow‑ups work: "what's 3×5" → "15", then "add 2 to that" routes to
   the text model with history (no screenshot) and answers "17", instead of the
   screenshot hijacking the answer. It's a fast heuristic — no extra model call — so
   it also saves latency by skipping the VLM when the screen isn't needed.
5. **Inference** — `CompanionManager` builds an Ollama chat request:
   - **Screen turn**: system prompt + history + the user turn with the screenshot
     attached, sent to `qwen2.5vl:3b`.
   - **Text turn**: no image, sent to `llama3.2:3b`.
   `OllamaClient.streamChat` streams the reply (`num_ctx` 8192 so a screenshot plus
   several turns of history can't overrun the context) and reports first‑token
   latency and decode tok/s.
6. **Pointing** — `PointingTagParser` pulls the `[POINT:x,y:label]` tag (or the
   VLM's native `[x1,y1,x2,y2:label]` bounding box, collapsed to its center) out of
   the reply. The remaining text is what gets spoken.
7. **Cursor** — the image‑pixel point is mapped to a global AppKit coordinate on
   the captured display (`CompanionManager.globalScreenLocation(forImagePoint:in:)`)
   and published as `detectedElementScreenLocation` /
   `detectedElementDisplayFrame`. `BlueCursorView` observes those and flies the blue
   triangle along a bezier arc to the element — the original overlay, untouched.
8. **Voice** — the answer is spoken **as it streams**: `SpokenTextSegmenter` peels
   off complete sentences (never the `[POINT]` tag) so the companion starts talking
   after the first sentence instead of waiting for the whole answer.
   `SpeechSynthesisCoordinator` prefers the neural Piper voice and falls back to
   Apple's synthesizer.

For a **browser command** (step 4), the turn skips inference entirely:
`BrowserCommandPlanner` resolves it to concrete URLs and `BrowserActionExecutor`
opens them — see below.

## Why a local VLM for coordinates (and not just a small model guessing pixels)

Small VLMs are unreliable at free‑form pixel grounding on dense UIs — the upstream
PR's `TAKEOVER.md` documents exactly this failure mode. `qwen2.5vl:3b` turned out
to be a sweet spot: it returns accurate **bounding boxes** for named UI elements,
and the parser collapses those to a center point. On a synthetic UI it grounded
targets to within ~15–20 px at sub‑second warm latency. The parser is intentionally
tolerant (accepts `[POINT:x,y]`, `[POINT:x1,y1,x2,y2]`, and bare boxes) so changing
the model later doesn't break pointing.

> Headroom: because pointing is just "name an element → resolve to a screen
> coordinate," a future version can snap the VLM's box to the nearest
> Vision‑framework OCR word box or Accessibility element for pixel‑perfect targets,
> fully locally. The architecture already isolates this in `PointingTagParser` +
> the coordinate mapping.

## Voice (neural, on‑device)

The robotic option (Apple's compact `AVSpeechSynthesizer` voices) is the fallback,
not the default. The default is a **Piper** neural voice (`en_US-ryan-medium`) run
through the **sherpa‑onnx** runtime, linked **in‑process** via its C API
(`CSherpaOnnx` + `PiperSpeechSynthesisClient`). In‑process matters: shelling out to
a TTS binary reloads the ~60 MB model every call (~3 s); holding it resident makes
synthesis ~0.05–0.1 s per sentence (≈20× real‑time) at a negligible battery cost.
The runtime + voice are vendored in `vendor/sherpa/` (fetch with
`scripts/fetch-tts.sh`) and copied into `LocalClicky.app/Contents/Resources/sherpa/`
by `build-app.sh`. If they're missing, the coordinator silently uses the Apple voice.

## Browser automation

A spoken command like "open a new tab, go to my gmail, and open up a draft" is
handled deterministically, not by pixel‑clicking:

- `BrowserCommandPlanner` (pure, in `LocalBrainKit`) maps the command to concrete
  URLs via a known‑site table — e.g. a draft → Gmail's real compose URL. No LLM JSON.
- `BrowserActionExecutor` opens those URLs in the default browser with
  `NSWorkspace.open`. This is **structurally safe**: the only thing it can do is
  navigate to a URL (reversible) — it cannot click, submit, send, or run page
  scripts — so every action falls in the user‑chosen "auto‑run safe" category. No
  Automation/AppleScript permission needed.

## Measured on this dev machine (M2, 16 GB)

Verified with `localbrain-harness` against the real models:

| path | cold (first call) | warm |
|---|---|---|
| text chat (`llama3.2:3b`) | ~4.5 s (model load) | first token ~0.5 s, ~45 tok/s |
| screen vision + pointing (`qwen2.5vl:3b`, 1280 px) | model load once | first token ~0.17 s, full answer ~1.4 s |
| neural TTS (`en_US-ryan-medium`) | ~0.4 s load (once) | ~0.05–0.1 s / sentence |

Latency work (verified before/after):
- **Warm‑up on launch** (`CompanionManager.warmUpLocalModels` + the voice graph)
  turns a ~4.5 s cold first query into ~0.17 s.
- **Sentence‑streaming TTS** starts speech ~0.8 s sooner than waiting for the whole
  answer.
- **Routing** skips the slower VLM for text turns.
- Screenshot stays at **1280 px**: the harness sweep showed shrinking it gives ~0
  latency benefit (first token already ~0.17 s) while hurting pointing accuracy.

Ollama keeps models warm (`keep_alive`), so the cold load is a one‑time cost per
model per session. Pointing accuracy on the synthetic test UI: ~14–20 px error.

## What's verified vs. what needs a human at the GUI

Verified here (headless / build): the local brain end‑to‑end (chat + vision +
pointing coordinates), all parser unit checks, a clean compile of the whole app
(16 files, no warnings, no cloud references), and that `LocalClicky.app` launches
as a registered menu‑bar GUI app and runs without crashing.

Needs you at the Mac (can't be automated): granting the four TCC permissions,
speaking into the mic, and visually confirming the blue cursor flies to the right
spot. The pipeline that produces those coordinates is verified; the on‑screen
animation is the original Clicky overlay driven by the same published properties.

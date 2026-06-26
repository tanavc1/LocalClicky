# LocalClicky architecture

LocalClicky keeps the original Clicky's menu‑bar UX and blue‑cursor overlay, and
replaces every cloud call with an on‑device equivalent. The only network traffic
is HTTP to a local Ollama server on `127.0.0.1:11434`.

## Packages / targets

| Target | Kind | Role |
|---|---|---|
| `LocalBrainKit` | library | The no‑UI "brain": Ollama client (incl. installed‑model listing + capability detection), `[POINT]` parser, prompts, model config + roles, conversation router, spoken‑text segmenter, browser‑ and app‑command planners. Pure logic, unit‑testable, no AppKit. |
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
   screen with ScreenCaptureKit (≤1152 px JPEG), excluding LocalClicky's own
   windows. The screenshot's pixel size defines the model's coordinate space.
4. **Routing** — `ConversationRouter` decides per turn whether this is a
   deterministic **action** (copy the last answer / launch an app / a browser
   command), needs the **screen**, or is a self‑contained/follow‑up **text**
   question. This is what makes follow‑ups work: "what's 3×5" → "15", then "add 2 to
   that" routes to the text model with history (no screenshot) and answers "17",
   instead of the screenshot hijacking the answer. It's a fast heuristic — no extra
   model call — so it also saves latency by skipping the VLM when the screen isn't
   needed. Action turns skip inference entirely (see [Actions](#actions)).
5. **Inference** — `CompanionManager` builds an Ollama chat request using the
   currently‑selected model for the role:
   - **Screen turn**: system prompt + history + the user turn with the screenshot
     attached, sent to the **vision model** (default `qwen2.5vl:3b`).
   - **Text turn**: no image, sent to the **text model** (default `llama3.2:3b`).
   `OllamaClient.streamChat` streams the reply and reports first‑token latency and
   decode tok/s. Every call uses the **same** `num_ctx`
   (`LocalModels.defaultContextWindow`, 8192) — roomy enough that a screenshot plus
   several turns of history can't overrun the context, and identical across roles so
   Ollama never reloads a model for a different context size (which would otherwise
   cost a multi‑second reload every time one model serves both roles).
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

For an **action** (step 4), the turn skips inference entirely and is resolved by
deterministic rules — see [Actions](#actions).

## Choosing your models

The defaults (`llama3.2:3b` text, `qwen2.5vl:3b` vision) are tuned for a 16 GB Mac,
but each role can be pointed at any installed Ollama model from the panel's
**Models** picker (persisted by `ModelPreferences`). The picker is hardware‑aware
and safe:

- `OllamaClient.listInstalledModels()` enumerates `/api/tags`; `capabilities(of:)`
  reads `/api/show`. The **vision** menu lists only models whose capabilities
  include `vision`; the **text** menu lists only models with `completion` (so an
  embedding‑only model can't be chosen). A text‑only model can never be wired to the
  screen role.
- Changing a model re‑warms it (`warmUpLocalModels`) and re‑checks install status.
  `OllamaClient.modelInstalled(_:among:)` normalizes tags (`llama3.2` ≡
  `llama3.2:latest`) so the "models missing" nudge is accurate.
- More RAM → pick `qwen3-vl:8b` for sharper grounding; less → a smaller text model.
  `swift run localbrain-harness --models` prints what's installed and each model's
  eligible role(s).

## Actions

Three kinds of spoken command are handled **deterministically** (no pixel‑clicking,
no model JSON), each structurally incapable of anything destructive:

- **Browser** — `BrowserCommandPlanner` (pure, in `LocalBrainKit`) maps "open a new
  tab, go to my gmail, and open up a draft" to concrete URLs via a known‑site table
  (a draft → Gmail's real compose URL); `BrowserActionExecutor` opens them with
  `NSWorkspace.open`. The only thing it can do is navigate to a URL — it cannot
  click, submit, send, or run page scripts.
- **App launch** — `AppCommandPlanner` extracts the app name from "launch spotify" /
  "open the notes app" (pure + unit‑tested); `LocalAppLauncher` resolves it to an
  app that's actually installed (Launch Services by name, which even finds system
  apps like Safari behind the read‑only firmlink, plus a fuzzy scan of the
  Applications folders) and opens it — as safe as double‑clicking in Finder. If no
  app matches, it falls back to a web search for the same words, then to saying it
  couldn't find it. Matching is conservative on purpose (e.g. "photoshop" never
  resolves to "Photos").
- **Clipboard** — "copy your answer" / "copy that to my clipboard" writes the
  companion's last real spoken answer to `NSPasteboard`. Useful right after asking
  it to write, translate, or summarize something.

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
- **Routing** skips the slower VLM for text turns (and skips inference entirely for
  action turns).
- **Consistent `num_ctx`** across text/vision/warm‑up means a model is never
  reloaded for a different context size — important when one model fills both roles.
- Screenshot stays at **≤1152 px**: the harness sweep showed shrinking it gives ~0
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

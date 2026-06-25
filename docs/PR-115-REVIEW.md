# Review of upstream PR #115 — "Add Local Mode — on-device inference next to Sonnet/Opus"

PR: https://github.com/farzaa/clicky/pull/115 (author: ShreyPatel4, branch `local-mode`,
33 files, +3878/−50)

This is the PR that prompted LocalClicky. It adds an on‑device "Local Mode" to the
original Clicky. Below is a careful review: what it does well, the bugs and risks,
and — most importantly — the functional gap it leaves, which is what LocalClicky
exists to close.

## Verdict

PR #115 is a **well‑engineered local *text‑chat* mode**, but it is **not a
fully‑local Clicky**. By design it turns off the two things that make Clicky
*Clicky*: **seeing your screen** and **pointing the blue cursor**. The PR's own
description says it plainly — in Local Mode "the screenshot isn't captured at
all" and pointing is disabled. So the headline feature still requires the cloud.

## What it gets right

- **Clean provider seam.** `BuddyChatProvider` mirrors the existing
  `BuddyTranscriptionProvider` pattern; `CloudChatProvider` wraps the untouched
  `ClaudeAPI`, so the Sonnet/Opus path is genuinely byte‑for‑byte unchanged.
  `BuddyTextToSpeechClient` does the same for TTS. Good, idiomatic seams.
- **Real on‑device pieces.** `LocalChatProvider` runs Llama‑3.2‑3B‑Instruct‑4bit
  via MLX; STT switches to Apple Speech with `requiresOnDeviceRecognition = true`
  (correctly only when supported); TTS uses `AVSpeechSynthesizer`. The offline
  voice loop is real.
- **Honest privacy follow‑through.** The author noticed the analytics layer ships
  the **full transcript + full response** to PostHog and gated those events in
  Local Mode. Good catch.
- **Thoughtful UX details.** First‑token latency badge, offline fail‑fast instead
  of a 120 s `waitsForConnectivity` hang, model‑download progress, and a
  permission‑free demo window.

## The core gap (acknowledged by the author)

- **No local vision.** In Local Mode the screenshot is never captured, so Clicky
  can't answer "what's on my screen?" — the half of the product the author flags
  as "the half of clicky Local Mode can't do yet."
- **No local pointing.** The blue cursor — the signature feature — does not fly to
  anything in Local Mode; `[POINT]` is stripped from a trimmed prompt.

So "Local Mode" really means *local text chat + local voice*. Screen understanding
and pointing still go to the cloud. **LocalClicky closes exactly this gap** with a
local VLM (`qwen2.5vl:3b`) that both answers screen questions and emits `[POINT]`
coordinates that drive the same overlay.

## Bugs, risks, and rough edges

1. **MLX can't be built without full Xcode.** The PR's own benchmark file notes:
   *"SwiftPM CLI can't compile MLX's Metal shaders."* That makes the local engine
   un‑buildable on a Command‑Line‑Tools‑only machine and bloats the app with a
   Metal‑shader toolchain dependency. (LocalClicky avoids this entirely by
   delegating inference to a local Ollama server over HTTP — no MLX in the app.)
2. **Two large, silent model downloads.** Llama‑3.2‑3B (~1.8 GB) plus, for the
   "takeover" prototype, Qwen2.5‑VL‑3B (~3 GB). First use kicks them off; on a
   near‑full disk this fails late and unpredictably.
3. **"Takeover" (autonomous computer‑use) is shipped unproven.** `TAKEOVER.md`
   states the executor/loop are untested in a live GUI and that small VLMs misclick
   on dense pro UIs. It synthesizes real mouse/keyboard `CGEvent`s behind a
   dry‑run/ESC‑kill‑switch gate — a genuine spike, not a shippable feature, and a
   meaningful safety surface to merge.
4. **The cloud path still phones home.** Even with Local Mode added, the
   Sonnet/Opus path still routes through the Cloudflare Worker *and* still sends
   the full transcript + response to PostHog. "Local Mode gates analytics" is true;
   "the app no longer has telemetry" is not. A *truly* no‑cloud build has to remove
   PostHog, Sparkle's appcast, and the FormSpark email capture, not just gate them.
5. **`LocalChatProvider` readiness can lie.** `init()` sets `modelReadiness =
   .loading` whenever a previously‑downloaded directory exists, even though nothing
   starts loading until `loadModelIfNeeded()` is later called — so the panel can
   show "loading" while idle.
6. **Stale‑download blind spot.** `previouslyDownloadedModelDirectory()` accepts any
   directory that merely *exists* on disk; a partial/corrupt download passes the
   check and then fails at load time with a less obvious error.
7. **Surprising trigger semantics.** Takeover/guided‑tour are gated on
   `!isNetworkAvailable`, so "take over …" silently does nothing while online — by
   design, but non‑obvious. Guided tour force‑switches to Sonnet and restores the
   user's model afterward (a bug the author fixed pre‑PR — good — but worth knowing).
8. **Prompt duplication.** The Local‑Mode system prompt is copy‑pasted between
   `CompanionManager` and the benchmark with a "keep in sync" comment — drift‑prone.

## What LocalClicky changed relative to PR #115

- Dropped MLX in favor of a local **Ollama** backend (no Xcode/Metal build
  requirement, no model bundling, models shared with the rest of the system).
- Added the missing half: **local screen vision + `[POINT]` pointing** via
  `qwen2.5vl:3b`, wired into the original blue‑cursor overlay unchanged.
- Removed **all** cloud + telemetry surfaces (Cloudflare Worker, PostHog, Sparkle,
  AssemblyAI, ElevenLabs, FormSpark, the Mux onboarding video), not just gated them.
- Did **not** port the unproven "takeover" autonomous computer‑use prototype; the
  safe, reliable, signature behavior (point — don't click) is preserved.

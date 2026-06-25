# LocalClicky

**A fully local, no-cloud rebuild of [Clicky](https://github.com/farzaa/clicky).**

Clicky is an AI buddy that lives next to your cursor: you hold a hotkey and talk
to it, it sees your screen, answers out loud, and a little blue cursor flies over
to point at the thing you asked about. The original sends your voice, your
screenshots, and your conversations to cloud services (Claude, AssemblyAI,
ElevenLabs) through a Cloudflare Worker.

**LocalClicky does all of it on your Mac. No cloud, no API keys, no account, no
analytics. Nothing you say, see, or ask ever leaves the machine.**

| Capability | Original Clicky | LocalClicky |
|---|---|---|
| Speech‑to‑text (push‑to‑talk) | AssemblyAI (cloud) | **Apple Speech, on‑device** |
| Answering / reasoning | Claude (cloud) | **Ollama `llama3.2:3b`, local** |
| Seeing your screen (vision) | Claude vision (cloud) | **Ollama `qwen2.5vl:3b`, local** |
| Pointing the blue cursor | Claude `[POINT]` coords | **local VLM `[POINT]` coords → same overlay** |
| Text‑to‑speech | ElevenLabs (cloud) | **`AVSpeechSynthesizer`, on‑device** |
| Analytics / telemetry | PostHog (full transcript!) | **none** |
| Auto‑updater | Sparkle (cloud appcast) | **none** |

Everything runs through a local [Ollama](https://ollama.com) server on
`127.0.0.1:11434`. The blue cursor, push‑to‑talk, multi‑monitor pointing, and the
menu‑bar UX are all preserved.

---

## Requirements

- Apple‑silicon Mac (M1/M2/M3/M4), macOS 14.2+ (16 GB RAM recommended)
- [Ollama](https://ollama.com/download) installed
- Xcode **Command Line Tools** (`xcode-select --install`) — full Xcode is *not*
  required to build the app

## Quick start

```bash
# 1. Get the local models + start the engine (one-time ~5 GB download)
scripts/bootstrap-ollama.sh

# 2. Fetch the neural voice + on-device TTS runtime (one-time ~85 MB download).
#    Optional — skip it and the app speaks with the built-in Apple voice instead.
scripts/fetch-tts.sh

# 3. Build, clean-install to /Applications, and launch — one command
scripts/install.sh
```

`install.sh` is the easy button: it ejects any old disk images, deletes every
previous copy, wipes stale macOS permission records, builds a fresh copy signed
with a **stable local identity**, installs it to **`/Applications/LocalClicky.app`**,
and opens it.

The app appears in your **menu bar** (top‑right, no dock icon). Click the icon,
grant the four permissions it asks for, then hold **Control + Option** and talk.

> **Permissions now stick.** Earlier ad‑hoc builds changed identity on every
> rebuild, so macOS kept dropping the Accessibility / Screen Recording grants
> ("I granted it but the app says I didn't"). The build is now signed with a
> persistent self‑signed certificate (`scripts/ensure-signing-identity.sh`),
> which anchors the app's identity so grants survive updates. Everything stays
> 100% local — this certificate never leaves your Mac and is not an Apple
> Developer ID.

If permissions ever get into a weird state again, just re-run `scripts/install.sh` —
it resets and re-grants from a clean slate. For a real distributable build, sign
with a Developer ID instead: `CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh`.

### Build only / share a DMG

```bash
scripts/build-app.sh        # build dist/LocalClicky.app without installing
scripts/package-dmg.sh      # wrap it into a drag-to-Applications DMG
```

### Prefer Xcode?

`open Package.swift` — Xcode opens the SwiftPM package directly. Select the
**LocalClicky** scheme to build/run, or set a signing team and Archive it.

## How to use it

- **Hold Control + Option and speak.** Release to send. LocalClicky transcribes
  on‑device, screenshots your current screen, asks the local vision model, speaks
  the answer, and — when it helps — flies the blue cursor to the relevant button,
  menu, or field.
- **Mode picker** (in the panel): **Vision** (default — sees your screen and can
  point) or **Text** (faster, no screenshot, for general questions).
- **Show LocalClicky** toggle: keep the cursor on screen always, or have it fade
  in only while you're talking to it.

## Permissions (all local)

| Permission | Why |
|---|---|
| Microphone | hear your push‑to‑talk voice (transcribed on‑device) |
| Accessibility | detect the global Control+Option hotkey |
| Screen Recording | screenshot your screen for the vision model |
| Screen Content | ScreenCaptureKit capture |

## Architecture

```
push-to-talk (⌃⌥, CGEvent tap)
  → Apple Speech (on-device STT)
    → ScreenCaptureKit screenshot
      → Ollama  ──►  qwen2.5vl:3b  (screen Q&A + [POINT:x,y])   ◄─ local
                └─►  llama3.2:3b   (text-only mode)              ◄─ local
        → PointingTagParser → screen-coordinate mapping
          → blue cursor overlay flies to the element  +  AVSpeechSynthesizer speaks
```

- **`Sources/LocalBrainKit/`** — the no‑UI "brain": the Ollama HTTP client, the
  `[POINT]` parser (handles both `[POINT:x,y]` and the VLM's native bounding
  boxes), prompts, and model config. Unit‑tested and exercisable headless.
- **`Sources/LocalClicky/`** — the menu‑bar app (SwiftUI/AppKit): the blue cursor
  overlay, push‑to‑talk pipeline, panel UI, screen capture, and `CompanionManager`
  (the state machine that wires it all together, fully local).
- **`Sources/localbrain-harness/`** — a CLI that runs the whole local pipeline
  against the real models, so you can verify it works without the GUI.

## Verify the brain without the GUI

```bash
swift run localbrain-harness                       # health + text chat
swift run localbrain-harness some-screenshot.png   # + vision Q&A + pointing
swift run localbrain-harness --selftest            # pointing-parser unit checks
```

## Docs

- [`docs/PR-115-REVIEW.md`](docs/PR-115-REVIEW.md) — review of the upstream
  "Local Mode" PR this project started from (what it does, its bugs, and the gap
  it leaves: no local vision/pointing).
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — deeper technical breakdown.

## Credit & license

LocalClicky is a local‑first remix of Farza's [Clicky](https://github.com/farzaa/clicky),
MIT licensed, same as the original. The blue cursor overlay, menu‑bar UX, and
push‑to‑talk pipeline are derived from that codebase; the inference, voice, and
vision layers were rebuilt to run entirely on‑device.

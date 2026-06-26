# LocalClicky

**A fully local, no-cloud rebuild of [Clicky](https://github.com/farzaa/clicky).**

Clicky is an AI buddy that lives next to your cursor: you hold a hotkey and talk
to it, it sees your screen, answers out loud, and a little blue cursor flies over
to point at the thing you asked about. The original sends your voice, your
screenshots, and your conversations to cloud services (Claude, AssemblyAI,
ElevenLabs) through a Cloudflare Worker.

**LocalClicky does all of it on your Mac. No cloud, no API keys, no account, no
analytics. Nothing you say, see, or ask ever leaves the machine.** The only
network traffic is HTTP to a local [Ollama](https://ollama.com) server on
`127.0.0.1`.

| Capability | Original Clicky | LocalClicky |
|---|---|---|
| Speech-to-text (push-to-talk) | AssemblyAI (cloud) | **Apple Speech, on-device** |
| Answering / reasoning | Claude (cloud) | **Ollama `llama3.2:3b`, local** |
| Seeing your screen (vision) | Claude vision (cloud) | **Ollama `qwen2.5vl:3b`, local** |
| Pointing the blue cursor | Claude `[POINT]` coords | **local VLM `[POINT]` coords → same overlay** |
| Text-to-speech | ElevenLabs (cloud) | **neural Piper voice on-device** (Apple voice fallback) |
| Pick your own models | — | **any model in your Ollama** (per-role, hardware-aware) |
| Open apps / browser / clipboard | — | **deterministic, on-device actions** |
| Analytics / telemetry | PostHog (full transcript!) | **none** |
| Auto-updater | Sparkle (cloud appcast) | **none** |

---

## Install (one command)

You need three things first — all free, all one-time:

1. An **Apple-silicon Mac** (M1/M2/M3/M4), macOS **14.2+**, 16 GB RAM recommended.
2. **[Ollama](https://ollama.com/download)** installed (`brew install --cask ollama` works too).
3. **Xcode Command Line Tools** — `xcode-select --install`. (Full Xcode is *not* required.)

Then clone and run the one-command setup:

```bash
git clone https://github.com/tanavc1/LocalClicky.git
cd LocalClicky
scripts/setup.sh
```

`setup.sh` is the easy button. It:

1. installs the local models into Ollama (one-time ~5 GB download),
2. fetches the neural voice + on-device TTS runtime (one-time ~85 MB; optional —
   skip it and the app uses the built-in Apple voice),
3. builds the app, cleanly removes any old copies, installs it to
   **`/Applications/LocalClicky.app`**, and launches it.

The app appears in your **menu bar** (top-right, no Dock icon). Click the icon,
grant the four permissions it asks for, then hold **Control + Option** and talk.

> **Permissions stick.** The build is signed with a persistent, locally-created
> certificate (`scripts/ensure-signing-identity.sh`), so macOS keeps your
> Accessibility / Screen Recording grants across rebuilds. This certificate never
> leaves your Mac — it's not an Apple Developer ID, and everything stays 100%
> local. If permissions ever get into a weird state, just re-run `scripts/setup.sh`.

### Run the steps yourself

```bash
scripts/bootstrap-ollama.sh   # ensure Ollama + the default models
scripts/fetch-tts.sh          # vendor the neural voice + TTS runtime (optional)
scripts/install.sh            # build, clean-install to /Applications, launch
scripts/build-app.sh          # just build dist/LocalClicky.app (no install)
scripts/package-dmg.sh        # wrap it into a drag-to-Applications DMG
```

### Prefer Xcode?

`open Package.swift` — Xcode opens the SwiftPM package directly. Select the
**LocalClicky** scheme to build/run.

## How to use it

- **Hold Control + Option and speak. Release to send.** LocalClicky transcribes
  on-device, screenshots your current screen, asks the local vision model, speaks
  the answer, and — when it helps — flies the blue cursor to the relevant button,
  menu, or field.
- **Ask about your screen:** *"what does this button do?"*, *"where do I click to
  export?"*, *"explain this error."*
- **Ask anything else** (no screenshot needed): *"what's 12 times 8?"*, *"write me
  a haiku about tabs"*, follow-ups like *"now add two to that."*
- **Tell it to do things** (see [Actions](#actions-what-it-can-do) below):
  *"open a new tab and go to gmail"*, *"launch spotify"*, *"copy your answer."*
- **Mode picker** (in the panel): **Vision** (default — sees your screen and can
  point) or **Text** (faster, no screenshot, for general questions).

## Actions (what it can *do*)

Beyond answering, LocalClicky can take a few **deterministic, on-device** actions.
These are intentionally not "let a 3B model click around your screen" — every
action is something safe and reversible that's resolved by exact rules, so it
either does exactly what you asked or tells you it couldn't. Nothing here can
submit a form, send a message, delete, or buy anything.

| Say… | What happens |
|---|---|
| "open a new tab and go to gmail" | opens the URL(s) in your default browser |
| "search for swift concurrency" | opens a web search |
| "search youtube for lofi", "coffee shops on google maps" | opens a scoped site search |
| "open gmail and start a draft" | opens a fresh Gmail compose window |
| "launch spotify", "open the notes app", "open terminal" | opens an installed Mac app |
| "copy your answer", "copy that to my clipboard" | copies the last spoken answer to the clipboard |

Browser navigation and app launching are exactly as safe as typing a URL or
double-clicking an app in Finder.

## Use your own models

Out of the box LocalClicky runs `llama3.2:3b` (text) and `qwen2.5vl:3b` (vision) —
small, fast, and comfortable on a 16 GB Mac. But you can point **either role at
any model installed in your own Ollama**, right from the panel's **Models**
section:

- **Text model** — the reasoning model used when the screen isn't needed. Any
  chat model works.
- **Vision model** — sees the screen and points the cursor. The picker only lists
  models that can actually accept images, so you can't accidentally wire the
  screen features to a text-only model.

Pull whatever fits your hardware and it shows up in the picker:

```bash
ollama pull qwen3-vl:8b     # sharper screen grounding (needs more RAM)
ollama pull llama3.1:8b     # stronger text reasoning
ollama pull qwen2.5vl:3b    # the default vision model
```

See everything you have installed and which role each can fill:

```bash
swift run localbrain-harness --models
```

**Recommendations:** on 16 GB, the defaults are the sweet spot. With 32 GB+,
`qwen3-vl:8b` for the vision role noticeably improves pointing on dense UIs. "Reset"
in the Models section restores the defaults.

## Permissions (all local)

| Permission | Why |
|---|---|
| Microphone | hear your push-to-talk voice (transcribed on-device) |
| Accessibility | detect the global Control+Option hotkey |
| Screen Recording | screenshot your screen for the vision model |
| Screen Content | ScreenCaptureKit capture |

## Architecture

```
push-to-talk (⌃⌥, CGEvent tap)
  → Apple Speech (on-device STT)
    → ConversationRouter  ──►  action? (browser / app / clipboard)  → done, on-device
                          └─►  question →
       ScreenCaptureKit screenshot (only if the screen is relevant)
         → Ollama  ──►  vision model  (screen Q&A + [POINT:x,y])   ◄─ local
                   └─►  text model    (no screenshot)              ◄─ local
           → PointingTagParser → screen-coordinate mapping
             → blue cursor overlay flies to the element  +  neural voice speaks
```

- **`Sources/LocalBrainKit/`** — the no-UI "brain": the Ollama HTTP client (with
  model listing + capability detection), the `[POINT]` parser, the conversation
  router, the browser/app command planners, prompts, and model config.
  Unit-tested and exercisable headless.
- **`Sources/LocalClicky/`** — the menu-bar app (SwiftUI/AppKit): blue cursor
  overlay, push-to-talk pipeline, panel UI, screen capture, neural TTS, the app
  launcher, and `CompanionManager` (the state machine that wires it all together).
- **`Sources/localbrain-harness/`** — a CLI that runs the whole local pipeline
  against the real models, so you can verify it works without the GUI.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full pipeline.

## Verify the brain without the GUI

```bash
swift run localbrain-harness --selftest            # parser + router + planners + matching
swift run localbrain-harness --models              # installed models + which role each can fill
swift run localbrain-harness                        # health + text chat
swift run localbrain-harness some-screenshot.png    # + vision Q&A + pointing
swift run localbrain-harness --benchmark shot.png 3 # latency benchmark
```

## Credit & license

LocalClicky is a local-first remix of Farza's [Clicky](https://github.com/farzaa/clicky),
MIT licensed, same as the original. The blue cursor overlay, menu-bar UX, and
push-to-talk pipeline are derived from that codebase; the inference, voice,
vision, and action layers were rebuilt to run entirely on-device.

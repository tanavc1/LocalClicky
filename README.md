# LocalClicky

**A fully local, no-cloud rebuild of [Clicky](https://github.com/farzaa/clicky).**

Credit to [Farza](https://github.com/farzaa) for open-sourcing Clicky and
[Shrey Patel](https://github.com/ShreyPatel4) for the initial
[local-mode PR](https://github.com/farzaa/clicky/pull/115).

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
| Seeing your screen (vision) | Claude vision (cloud) | **Ollama `moondream`, local** |
| Pointing the blue cursor | Claude `[POINT]` coords | **local grounding VLM `qwen2.5vl:3b` → same overlay** |
| Text-to-speech | ElevenLabs (cloud) | **neural Piper voice on-device** (Apple voice fallback) |
| Hardware tuning | — | **autotune-style advisor picks the best models + keeps them warm** |
| Pick / download models | — | **any model in your Ollama; one-click in-app downloads (fit-gated)** |
| Open apps / browser / clipboard | — | **deterministic, on-device actions** |
| Internet (opt-in) | — | **on request only** — *"what's the latest… online"* (the one cloud exception) |
| Analytics / telemetry | PostHog (full transcript!) | **none** |
| Auto-updater | Sparkle (cloud appcast) | **none** |

The blue cursor's **point-at-things** accuracy is ~9/10 (up from ~1/2 in the first
local build — see [`docs/benchmarks/`](docs/benchmarks)). Everything stays on your
Mac except the single, clearly-flagged, opt-in web lookup.

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
grant the three permissions it asks for, then hold **Control + Option** and talk.

> **Permissions stick.** The build is signed with a persistent, locally-created
> certificate (`scripts/ensure-signing-identity.sh`), so macOS keeps your
> Accessibility / Screen Recording grants across rebuilds. This certificate never
> leaves your Mac — it's not an Apple Developer ID, and everything stays 100%
> local. If permissions ever get into a weird state, just re-run `scripts/setup.sh`.

### Run the steps yourself

```bash
scripts/bootstrap-ollama.sh   # ensure Ollama + the default models
scripts/fetch-tts.sh          # vendor the neural voice + TTS runtime (optional)
scripts/install.sh            # build + clean-install to /Applications (resets permissions)
scripts/update.sh             # rebuild + reinstall in place, KEEPING your permissions
scripts/build-app.sh          # just build dist/LocalClicky.app (no install)
scripts/package-dmg.sh        # wrap it into a drag-to-Applications DMG
```

> **Updating later?** Use `scripts/update.sh` — it reinstalls the new build with
> the same stable signing identity, so your granted permissions carry over and you
> don't have to re-grant anything. (`install.sh` is the from-scratch path that
> wipes and re-grants.) The first build in a new login session may show a one-time
> keychain prompt for the local signing key — click **Always Allow**.

### Prefer Xcode?

`open Package.swift` — Xcode opens the SwiftPM package directly. Select the
**LocalClicky** scheme to build/run.

## Is it safe? (yes — here's exactly why)

- **It's open source.** Every line that runs is in this repo. The inference, voice,
  vision, and actions are all on-device.
- **No cloud, no telemetry, no account, no API keys.** The *only* outbound traffic
  is: (1) localhost to your own Ollama, (2) one-time setup downloads you trigger
  (Ollama itself + models, from `ollama.com`), and (3) the **opt-in** web lookup,
  which only runs when you explicitly ask it to (and says *"checking the web…"*).
  A `grep` for trackers/keys comes back empty — there's nothing to find.
- **No app can quietly watch you.** The screen is captured *only* while you hold
  the hotkey, and the image goes straight to your local model and nowhere else.
- **Gatekeeper note (unsigned build):** because this is a free, self-built app (not
  yet notarized with an Apple Developer ID), the first open may show *"LocalClicky
  can't be opened because Apple cannot check it for malicious software."* That's
  the standard warning for any app outside the App Store — **right-click the app →
  Open → Open**, once, and macOS remembers it. (If you have an Apple Developer
  cert, set `CODESIGN_IDENTITY=...` before `scripts/build-app.sh` and it'll be
  notarization-ready, removing the warning entirely.)

## How to use it

- **Hold Control + Option and speak. Release to send.** LocalClicky transcribes
  on-device, screenshots your current screen, asks the local vision model, speaks
  the answer, and — when it helps — flies the blue cursor to the relevant button,
  menu, or field.
- **Ask about your screen:** *"what does this button do?"*, *"where do I click to
  export?"*, *"explain this error."*
- **Ask anything else** (no screenshot needed): *"what's 12 times 8?"*, *"write me
  a haiku about tabs"*, follow-ups like *"now add two to that."*
- **Get an answer as text** beside the cursor: *"give me Martin Luther King's
  birthday in text"*, *"give text."* — a tight, honest answer in the blue bubble.
- **Look something up online** (the one opt-in internet feature): *"what's the
  latest on the mars mission online"*, *"search the web and tell me who won."*
  It shows *"checking the web…"* while it fetches, then answers — see
  [Internet](#internet-the-one-opt-in-online-feature).
- **Tell it to do things** (see [Actions](#actions-what-it-can-do) below):
  *"open a new tab and go to gmail"*, *"launch spotify"*, *"copy your answer."*
- **Mode picker** (in the panel): **Vision** (default — sees your screen and can
  point) or **Text** (faster, no screenshot, for general questions).

On the **very first launch**, LocalClicky introduces itself in the blue text
beside your cursor (how to activate it), then cracks one quick, screen-aware joke
about whatever you're doing — and that's the whole "onboarding." No video, no music.

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

## Internet (the one opt-in online feature)

LocalClicky is local-first, but a few questions genuinely need the live web
("what's the latest on X", current events). When — and **only** when — you ask
with an explicit internet phrasing (*"…online"*, *"what's the latest…"*, *"search
the web and tell me…"*), it fetches results through a web reader, has your **local**
model summarize them, and speaks the answer. While it's fetching, the blue text
reads *"checking the web…"* so it's always obvious this is the single moment
LocalClicky reaches outside your Mac. Every other turn stays 100% local. (If you
have the [`agent-reach`](https://github.com/Panniantong/agent-reach) CLI installed,
it's detected; the built-in path needs nothing extra. See
[`docs/agent-reach-spike.md`](docs/agent-reach-spike.md).)

## Use your own models

Out of the box LocalClicky runs `llama3.2:3b` (text), `moondream` (screen describe),
and `qwen2.5vl:3b` (pointing/grounding) — small, fast, and comfortable on a 16 GB
Mac. A built-in **autotune-style advisor** detects your RAM and recommends the best
fit (and, if you have the [`autotune`](https://autotunellm.com) CLI, uses it too),
keeping the right models warm in memory. On a different Mac it adapts: lighter
models on 8 GB, stronger ones (e.g. `qwen2.5-coder:7b`, `qwen3-vl:8b`) on 32 GB+.

**One-click downloads, in the app.** If Ollama isn't installed, the panel shows a
**Download Ollama** button. The **Add a model** dropdown lists models that *fit your
Mac* (with sizes and a "best for your mac" marker); pick one, hit **Download**, and
it pulls with a progress bar and warms straight into memory — no Terminal needed.

You can also point **either role at any model installed in your own Ollama**, right
from the panel's **Models** section:

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
| Screen Recording | screenshot your screen for the vision model via ScreenCaptureKit |

## Architecture

```
push-to-talk (⌃⌥, CGEvent tap)
  → Apple Speech (on-device STT)
    → ConversationRouter ──► action?  (browser / app / clipboard)        → on-device
                         ├─► give-text                                    → concise answer in blue text
                         ├─► web-reach (opt-in, "…online")                → Jina read → local model summarizes
                         └─► question →
       ScreenCaptureKit screenshot (only if the screen is relevant)
         → Ollama ──► describe turn → vision model (Moondream)            ◄─ local
                  ├─► point turn    → grounding model (qwen2.5vl, [POINT]) ◄─ local
                  └─► text turn     → text model (no screenshot)          ◄─ local
           → PointingTagParser → screen-coordinate mapping
             → blue cursor overlay flies to the element  +  neural voice speaks

   HardwareAdvisor (+ optional autotune CLI) picks the models, right-sizes each
   model's KV cache (num_ctx), and keeps the resident set warm in RAM.
```

- **`Sources/LocalBrainKit/`** — the no-UI "brain": the Ollama HTTP client (chat +
  streaming model `pull`), the format-robust `[POINT]` parser, the conversation
  router, the browser/app command planners, prompts, the `HardwareAdvisor` +
  `AutotuneBridge` (model recommendation), and `WebReachTool` (the opt-in web
  lookup). Unit-tested and exercisable headless.
- **`Sources/LocalClicky/`** — the menu-bar app (SwiftUI/AppKit): blue cursor
  overlay, push-to-talk pipeline, panel UI, screen capture, neural TTS, the app
  launcher, and `CompanionManager` (the state machine that wires it all together).
- **`Sources/localbrain-harness/`** — a CLI that runs the whole local pipeline
  against the real models, so you can verify it works without the GUI.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full pipeline.

## Verify the brain without the GUI

```bash
swift run localbrain-harness --selftest                  # ~90 unit checks: parser, router, advisor, prompts, safety
swift run localbrain-harness --advise                    # hardware profile + recommended models (+ autotune if present)
swift run localbrain-harness --models                    # installed models + which role each can fill
swift run localbrain-harness --e2e some-screenshot.png   # full pipeline vs real models (text, describe, point, joke)
swift run localbrain-harness --webreach "latest mars news"  # the opt-in web tool, end-to-end
swift run localbrain-harness --benchmark-suite shot.png 3 after   # before/after benchmark report → docs/benchmarks/
swift run localbrain-harness some-screenshot.png         # one-shot: health + text chat + vision Q&A
```

## Credit & license

LocalClicky is a local-first remix of Farza's [Clicky](https://github.com/farzaa/clicky),
MIT licensed, same as the original. The blue cursor overlay, menu-bar UX, and
push-to-talk pipeline are derived from that codebase; the inference, voice,
vision, and action layers were rebuilt to run entirely on-device.

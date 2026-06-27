# agent-reach spike — findings & decision

**Goal (from the brief):** evaluate https://github.com/Panniantong/agent-reach as an
internet/website tool LocalClicky can call when a query needs the web — and only
integrate it if it *truly works and is helpful* and is *safe* for a public Mac app.

## What agent-reach actually is

- A **Python + Node** capability layer that routes across many platforms
  (Twitter/X, Reddit, YouTube, GitHub, RSS, general web, etc.).
- **Not on PyPI.** Real install is `pip install` (or pipx) from the GitHub zip,
  then `agent-reach install --env=auto`, which **provisions system-wide tooling**:
  `gh` CLI, Node.js, `mcporter`, Exa search, `yt-dlp`. Advanced platforms need
  **browser-cookie auth**.
- Under the hood, its **core, no-credential web capabilities are tiny**:
  - **Read a page:** `curl https://r.jina.ai/<URL>` (Jina Reader → clean markdown).
  - **Search:** Exa via `mcporter` (needs setup/keys).

## What I tested (works ✅)

- **Jina Reader read** (`r.jina.ai/<url>`): returned clean markdown for a static
  page (Claude Shannon) **and live current content** (today's Hacker News front
  page) — genuinely useful, no key.
- **Keyless search**: `s.jina.ai` now requires an API key (401), **but** reading a
  DuckDuckGo HTML results page through Jina works keyless:
  `r.jina.ai/https://duckduckgo.com/html/?q=<query>` → ranked results as markdown
  (correctly surfaced the 2024 Nobel Physics page). So **read + search both work
  with no keys and no install**, via the single `r.jina.ai` endpoint.

## Decision (gate: integrate the core, not the heavy installer)

Bundling the **full** agent-reach into a one-click, "safe Mac app" is **not**
appropriate: it isn't on PyPI, and `agent-reach install` mutates the user's system
(global Node/gh/mcporter/Exa/yt-dlp) and some channels need cookie auth — exactly
the kind of invasive setup the brief said to avoid ("cause no issues").

So LocalClicky implements **agent-reach's proven core capability natively** — a
`WebReachTool` that does web **search** (DuckDuckGo-via-Jina) and **read**
(`r.jina.ai/<url>`), then lets the local text model synthesize a concise answer.
This is the same mechanism agent-reach uses for web reading, with **zero install,
no keys, no cookies**. It is:

- **Opt-in + narrowly triggered:** only fires when a query clearly needs the
  internet ("look it up online", "what's the latest…", "search the web and tell
  me…"), via the `.webReach` route — never for normal screen/voice turns.
- **Clearly flagged:** shows "checking the web…" in the blue side-text, because
  this is the **one** feature that leaves LocalClicky's no-cloud guarantee (the
  request goes to `r.jina.ai`). Everything else stays fully local.
- **Hybrid-aware:** if the user already has the `agent-reach` CLI installed, it's
  detected; the native Jina path is the always-works baseline either way.

This honors "test before implementing" and "trigger only when the tool is truly
required," while keeping the public release safe and dependency-free.

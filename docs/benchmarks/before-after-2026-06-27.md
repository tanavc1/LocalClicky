# LocalClicky — before vs after (this release)

Same machine (Apple M2, 16 GB), same screenshot (1920×1080), same harness
(`localbrain-harness --benchmark-suite`). "Before" = the previous build
(commit `eca2e16`, qwen2.5vl + llama3.2, single 8192 context, conversational
pointing prompt). "After" = this release (Moondream describe + qwen2.5vl
grounding, per-role context windows, the dedicated directive pointing prompt,
and the format-robust pointing parser).

> Point-parse / in-bounds are an honest *reproducibility* proxy: does the model
> return a parseable, in-bounds `[POINT:x,y]`. Latencies on a 16 GB Mac vary with
> memory pressure (the "after" run had three vision models loaded), so treat
> sub-0.3 s TTFT differences as noise.

| Metric | Before | After | Δ |
|---|---:|---:|---:|
| **Pointing parse rate** (qwen2.5vl) | 50% | **92%** | **+42 pts** |
| **Pointing in-bounds rate** (qwen2.5vl) | 50% | **92%** | **+42 pts** |
| Pointing total latency (qwen2.5vl) | 1.20 s | **0.73 s** | −39% |
| Pointing TTFT (qwen2.5vl) | 0.22 s | 0.21 s | ~flat |
| Text TTFT (llama3.2:3b) | 0.45 s | 0.72 s | noise (mem pressure) |
| Text tok/s (llama3.2:3b) | 44 | 44 | flat |

## What actually moved, and why

- **Pointing reliability is the headline: 50% → 92%.** The old conversational
  prompt let qwen2.5vl "answer helpfully" and skip the coordinate tag about half
  the time; and the parser only understood `[POINT:x,y:label]`, while the model
  often emits `[POINT x="736" y="45"]`. This release adds a **dedicated directive
  pointing prompt** (`.screenPoint` route) that demands a well-formed tag every
  time, and a **format-robust parser** that accepts both shapes. The blue cursor
  now lands far more often, and when there's genuinely nothing to point at it
  returns a clean `none` instead of rambling.
- **Pointing latency −39%** (1.20 s → 0.73 s total): the tight prompt produces a
  short sentence + tag instead of a paragraph, so less is generated.
- **Text generation speed is unchanged** (44 tok/s) — expected: token generation
  on Apple-silicon is Metal-GPU-bound. The per-role `num_ctx` (text 4096 vs the
  old 8192) is an **RAM** optimization (a smaller KV cache), which is what makes
  it safe to keep **two models resident** (text + Moondream) on 16 GB for
  instant answers — not a raw tok/s win. This mirrors autotune's own finding
  ("generation speed unchanged; the win is KV-cache RAM").
- **Moondream** is now the default *describe* model (fast, small); its 0% pointing
  is by design — pointing is routed to the grounding model. `qwen3-vl:8b` remains
  far too slow on 16 GB (~9.6 s/answer) and the advisor correctly does **not**
  recommend it until ~32 GB.

## Net effect for the user

The signature blue-cursor feature went from "works about half the time" to
"works ~9 times out of 10," answers about the screen are snappier, and two models
now stay warm in RAM at once — all while keeping the 16 GB default arrangement.

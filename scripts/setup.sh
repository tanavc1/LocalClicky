#!/usr/bin/env bash
#
# setup.sh — the one command that takes a fresh clone to a running LocalClicky.
# Does everything, in order, and is safe to re-run:
#
#   1. Ensures Ollama + the default local models are installed (bootstrap-ollama).
#   2. Fetches the neural voice + on-device TTS runtime (fetch-tts; optional —
#      if it fails, the app simply speaks with the built-in Apple voice).
#   3. Builds, clean-installs to /Applications, and launches the app (install).
#
# Usage:  scripts/setup.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "════════════════════════════════════════════════════════════"
echo "  LocalClicky setup — fully local, nothing leaves your Mac"
echo "════════════════════════════════════════════════════════════"
echo ""

echo "▸ Step 1/3: local models (Ollama)"
"$ROOT/scripts/bootstrap-ollama.sh"
echo ""

echo "▸ Step 2/3: neural voice (optional)"
if ! "$ROOT/scripts/fetch-tts.sh"; then
  echo "  (neural voice download failed — that's fine, the app will use the"
  echo "   built-in Apple voice instead. You can re-run scripts/fetch-tts.sh later.)"
fi
echo ""

echo "▸ Step 3/3: build + install + launch"
"$ROOT/scripts/install.sh"

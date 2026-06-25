#!/usr/bin/env bash
#
# bootstrap-ollama.sh — make sure the local inference engine LocalClicky needs is
# ready: Ollama installed, the server running, and both models pulled. Run once
# before first launch (and any time you want to confirm the engine is healthy).
#
set -euo pipefail

CHAT_MODEL="llama3.2:3b"
VISION_MODEL="qwen2.5vl:3b"

echo "==> Checking Ollama…"
if ! command -v ollama >/dev/null 2>&1; then
  cat <<EOF
Ollama isn't installed. Install it, then re-run this script:
  • Download:  https://ollama.com/download
  • Homebrew:  brew install --cask ollama
EOF
  exit 1
fi
echo "    ollama $(ollama --version 2>/dev/null | head -1)"

echo "==> Checking the Ollama server…"
if curl -s --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "    server already running."
else
  echo "    starting 'ollama serve' in the background…"
  (ollama serve >/dev/null 2>&1 &)
  for _ in $(seq 1 15); do
    sleep 1
    curl -s --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
  done
  curl -s --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 \
    || { echo "couldn't reach the server; start it manually: ollama serve"; exit 1; }
  echo "    server up."
fi

echo "==> Ensuring models are installed (this is a one-time download)…"
for model in "$CHAT_MODEL" "$VISION_MODEL"; do
  if ollama list | awk '{print $1}' | grep -qx "$model"; then
    echo "    ✓ $model already installed"
  else
    echo "    ↓ pulling $model …"
    ollama pull "$model"
  fi
done

echo ""
echo "==> Local engine ready. LocalClicky will run fully on-device."

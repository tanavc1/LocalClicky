#!/usr/bin/env bash
#
# fetch-tts.sh — download the native (Apple-silicon) neural text-to-speech runtime
# and voice that give LocalClicky its human-sounding voice, into vendor/sherpa.
#
#   * sherpa-onnx (Apache-2.0) — the in-process TTS runtime, linked via its C API
#     so the model loads once and synthesis is ~20x real-time.
#   * Piper voice en_US-ryan-medium (MIT) — a natural male English voice.
#
# Everything is on-device; this script just fetches the binaries once. If the
# runtime is missing at runtime, LocalClicky falls back to the Apple voice.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$ROOT/vendor/sherpa"
SHERPA_VER="1.13.3"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading sherpa-onnx $SHERPA_VER (osx-arm64)…"
curl -L --fail \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VER}/sherpa-onnx-v${SHERPA_VER}-osx-arm64-shared.tar.bz2" \
  -o "$TMP/sherpa.tar.bz2"
tar -xjf "$TMP/sherpa.tar.bz2" -C "$TMP"
SDIR="$TMP/sherpa-onnx-v${SHERPA_VER}-osx-arm64-shared"

echo "==> Downloading Piper voice en_US-ryan-medium…"
curl -L --fail \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-ryan-medium.tar.bz2" \
  -o "$TMP/voice.tar.bz2"
tar -xjf "$TMP/voice.tar.bz2" -C "$TMP"

echo "==> Installing into vendor/sherpa…"
mkdir -p "$DST/lib" "$DST/voice" "$ROOT/Sources/CSherpaOnnx/include"
cp "$SDIR/lib/libsherpa-onnx-c-api.dylib" "$DST/lib/"
cp "$SDIR/lib/libonnxruntime.1.24.4.dylib" "$DST/lib/"
( cd "$DST/lib" && ln -sf libonnxruntime.1.24.4.dylib libonnxruntime.dylib )
cp "$SDIR/include/sherpa-onnx/c-api/c-api.h" "$ROOT/Sources/CSherpaOnnx/include/"
cp -R "$TMP/vits-piper-en_US-ryan-medium/." "$DST/voice/"
xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true

echo ""
echo "==> Neural TTS ready in vendor/sherpa (runtime + en_US-ryan-medium voice)."

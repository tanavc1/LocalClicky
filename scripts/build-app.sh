#!/usr/bin/env bash
#
# build-app.sh — compile LocalClicky and assemble it into a runnable
# LocalClicky.app bundle (icon + Info.plist + resources + code signature).
#
# Works with just the Xcode Command Line Tools — no full Xcode required, because
# LocalClicky has no heavy native dependencies (all inference is delegated to a
# local Ollama server over HTTP). For a Developer-ID-signed build, export
# CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" first.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="LocalClicky"
CONFIG="${CONFIG:-release}"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME ($CONFIG)…"
swift build -c "$CONFIG" --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

echo "==> Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Sources/LocalClicky/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/LocalClicky/Resources/"*.mp3 "$APP/Contents/Resources/" 2>/dev/null || true
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Bundling neural TTS runtime + Piper voice…"
SHERPA_DST="$APP/Contents/Resources/sherpa"
if [ -f "$ROOT/vendor/sherpa/voice/en_US-ryan-medium.onnx" ]; then
  mkdir -p "$SHERPA_DST/lib" "$SHERPA_DST/voice"
  # Only the two dylibs the app actually loads (skip the symlink to keep it lean).
  cp "$ROOT/vendor/sherpa/lib/libsherpa-onnx-c-api.dylib" "$SHERPA_DST/lib/"
  cp "$ROOT/vendor/sherpa/lib/libonnxruntime.1.24.4.dylib" "$SHERPA_DST/lib/"
  cp -R "$ROOT/vendor/sherpa/voice/." "$SHERPA_DST/voice/"
  xattr -dr com.apple.quarantine "$SHERPA_DST" 2>/dev/null || true
else
  echo "   (vendor/sherpa missing — run scripts/fetch-tts.sh; app will fall back to the Apple voice)"
fi

echo "==> Building app icon…"
ICONSET="$DIST_DIR/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
ICON_SRC="$ROOT/scripts/AppIcon-1024.png"
if [ -f "$ICON_SRC" ]; then
  for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z "$((sz*2))" "$((sz*2))" "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "   (no scripts/AppIcon-1024.png — skipping icon)"
fi

echo "==> Code signing…"
ENT="$ROOT/Sources/LocalClicky/Resources/LocalClicky.entitlements"
# Pick a signing identity, in priority order:
#   1. $CODESIGN_IDENTITY  — e.g. a Developer ID for real distribution.
#   2. A persistent, locally-created self-signed identity (the default). This is
#      what makes macOS permission grants STICK across rebuilds. An ad-hoc ("-")
#      signature pins the app's identity to its cdhash, which changes every build,
#      so TCC drops the Accessibility / Screen Recording grant and the app reports
#      "not granted" even though System Settings still shows the toggle on. A real
#      certificate anchors the Designated Requirement to the (stable) certificate
#      instead. See scripts/ensure-signing-identity.sh.
#   3. ADHOC=1 forces the old ad-hoc behavior.
if [ "${ADHOC:-0}" = "1" ]; then
  IDENTITY="-"
  CODESIGN_KEYCHAIN_ARGS=()
elif [ -n "${CODESIGN_IDENTITY:-}" ]; then
  IDENTITY="$CODESIGN_IDENTITY"
  CODESIGN_KEYCHAIN_ARGS=()
else
  IDENTITY="$("$ROOT/scripts/ensure-signing-identity.sh")"
  LOCAL_SIGNING_KEYCHAIN="$HOME/Library/Keychains/LocalClickySigning.keychain-db"
  if [ -f "$LOCAL_SIGNING_KEYCHAIN" ]; then
    CODESIGN_KEYCHAIN_ARGS=(--keychain "$LOCAL_SIGNING_KEYCHAIN")
  else
    CODESIGN_KEYCHAIN_ARGS=()
  fi
fi
echo "    signing identity: $IDENTITY"
# Sign the bundled dylibs first (inside-out), so the app signature is valid.
if [ -d "$SHERPA_DST/lib" ]; then
  codesign --force "${CODESIGN_KEYCHAIN_ARGS[@]}" --sign "$IDENTITY" "$SHERPA_DST/lib/libonnxruntime.1.24.4.dylib"
  codesign --force "${CODESIGN_KEYCHAIN_ARGS[@]}" --sign "$IDENTITY" "$SHERPA_DST/lib/libsherpa-onnx-c-api.dylib"
fi
codesign --force --deep "${CODESIGN_KEYCHAIN_ARGS[@]}" --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --verbose "$APP" 2>&1 | tail -1 || true
# Show the Designated Requirement so it's obvious the identity is cert-anchored
# (stable) rather than cdhash-pinned (resets permissions on every rebuild).
echo "    $(codesign -d -r- "$APP" 2>&1 | grep -i 'designated' || true)"

echo ""
echo "==> Done: $APP"
echo "    To install it cleanly (recommended), run:  scripts/install.sh"
echo "    Or just run this build in place:           open \"$APP\""

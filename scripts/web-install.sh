#!/usr/bin/env bash
#
# web-install.sh — the truly one-step installer for LocalClicky.
#
# Run it straight from the web:
#
#   curl -fsSL https://raw.githubusercontent.com/tanavc1/LocalClicky/main/scripts/web-install.sh | bash
#
# It downloads the latest released LocalClicky.dmg, copies the app to
# /Applications, strips the "downloaded from the internet" quarantine flag (so
# macOS opens it with a normal double-click instead of the "Apple cannot check
# it for malware" block — this app is signed with a local certificate, not
# notarized), and launches it. No git clone, no Xcode, no build.
#
# The app itself then walks you through the rest (installing Ollama + the local
# models) from its menu-bar panel.
set -euo pipefail

REPO="tanavc1/LocalClicky"
APP_NAME="LocalClicky"
DMG_URL="https://github.com/$REPO/releases/latest/download/$APP_NAME.dmg"
INSTALLED="/Applications/$APP_NAME.app"

say() { printf '\033[1;34m%s\033[0m\n' "$*"; }

# Apple-silicon + macOS guardrail (the app needs on-device Apple-silicon inference).
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "LocalClicky needs an Apple-silicon Mac (M1/M2/M3/M4) on macOS 14.2+."
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "${MOUNT:-}" ] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true' EXIT

say "==> Downloading the latest ${APP_NAME}…"
curl -fL# "$DMG_URL" -o "$TMP/$APP_NAME.dmg"

say "==> Quitting any running copy…"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1

say "==> Installing to /Applications…"
MOUNT="$TMP/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$TMP/$APP_NAME.dmg" -nobrowse -quiet -mountpoint "$MOUNT"
rm -rf "$INSTALLED"
ditto "$MOUNT/$APP_NAME.app" "$INSTALLED"
hdiutil detach "$MOUNT" -quiet
MOUNT=""
# This is an explicit, user-initiated install — clear quarantine/provenance so it
# opens with a plain double-click (no Gatekeeper right-click dance).
xattr -cr "$INSTALLED" 2>/dev/null || true

say "==> Launching ${APP_NAME}…"
open "$INSTALLED"

cat <<'DONE'

  ============================================================
  ✅ LocalClicky is installed and launched.
  ============================================================

  It lives in the MENU BAR (top-right), not the Dock. Click its
  icon, then:

    1. Grant the 3 permissions (Microphone, Accessibility,
       Screen Recording). They stick from here on.
    2. If you don't have Ollama + models yet, use the panel's
       one-click buttons to install them.
    3. Hold  Control + Option  to talk; release to send.

DONE

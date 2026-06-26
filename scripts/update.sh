#!/usr/bin/env bash
#
# update.sh — rebuild LocalClicky and install the new version IN PLACE, without
# touching your permissions. Use this to update an install that already works
# (vs. install.sh, which wipes and re-grants permissions from a clean slate).
#
# Because the build is signed with the same stable local identity as before, the
# app's "Designated Requirement" doesn't change, so macOS keeps your existing
# Accessibility / Screen Recording / Microphone grants — no re-granting needed.
#
# It:
#   1. Quits any running LocalClicky and ejects stale disk images.
#   2. Builds a fresh, stably-signed app (the FIRST build in a new login session
#      may pop a one-time keychain prompt for the local signing key — click
#      "Always Allow" and it won't ask again).
#   3. Removes old copies (Downloads, Desktop, ~/Applications, dist DMG).
#   4. Installs to /Applications and strips the quarantine flag.
#   5. Relaunches.
#
# Usage:  scripts/update.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="LocalClicky"
INSTALLED="/Applications/$APP_NAME.app"
BUILT="$ROOT/dist/$APP_NAME.app"

echo "==> 1/5  Quitting $APP_NAME and ejecting stale disk images…"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1
for vol in /Volumes/"$APP_NAME"*; do
  [ -d "$vol" ] || continue
  hdiutil detach "$vol" -force >/dev/null 2>&1 && echo "    ejected $vol" || true
done

echo "==> 2/5  Building a fresh, stably-signed app…"
echo "    (if a keychain prompt appears for \"LocalClicky Local Signing\", click"
echo "     Always Allow — this is the local signing key, it never leaves your Mac.)"
"$ROOT/scripts/build-app.sh"
[ -d "$BUILT" ] || { echo "build did not produce $BUILT"; exit 1; }

echo "==> 3/5  Removing old copies of the app…"
for p in "$HOME/Downloads/$APP_NAME.app" "$HOME/Desktop/$APP_NAME.app" \
         "$HOME/Applications/$APP_NAME.app" "$ROOT/dist/$APP_NAME.dmg"; do
  if [ -e "$p" ]; then rm -rf "$p" && echo "    removed $p"; fi
done

echo "==> 4/5  Installing to /Applications (keeping your permissions)…"
ditto "$BUILT" "$INSTALLED"
xattr -cr "$INSTALLED" 2>/dev/null || true

echo "==> 5/5  Launching $APP_NAME…"
open "$INSTALLED"

echo ""
echo "  ✅ Updated: $INSTALLED"
echo "  LocalClicky is in the menu bar (top-right). Your existing permissions"
echo "  carry over because the app keeps the same stable signing identity."

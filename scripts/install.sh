#!/usr/bin/env bash
#
# install.sh — the single command that (re)installs LocalClicky cleanly and
# fixes the "I granted permission but the app says I didn't" problem for good.
#
# It does, in order:
#   1. Quits any running LocalClicky and ejects every stale mounted disk image.
#   2. Deletes every old copy of the app (old installs, Downloads, Desktop, DMG).
#   3. Wipes macOS's stale permission (TCC) records + saved settings for the app,
#      so you start from a clean slate with no contradictory "granted" entries.
#   4. Builds one fresh copy signed with a STABLE identity (so grants now stick).
#   5. Installs it to /Applications and removes the "downloaded" quarantine flag
#      so it opens with a normal double-click.
#
# Usage:  scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="LocalClicky"
BUNDLE_ID="com.localclicky.LocalClicky"
INSTALLED="/Applications/$APP_NAME.app"
BUILT="$ROOT/dist/$APP_NAME.app"

echo "==> 1/6  Quitting LocalClicky and ejecting stale disk images…"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1
for vol in /Volumes/"$APP_NAME"*; do
  [ -d "$vol" ] || continue
  if hdiutil detach "$vol" -force >/dev/null 2>&1; then
    echo "    ejected $vol"
  fi
done

echo "==> 2/6  Removing old copies of the app…"
for p in "$INSTALLED" "$BUILT" "$ROOT/dist/$APP_NAME.dmg" \
         "$HOME/Downloads/$APP_NAME.app" "$HOME/Desktop/$APP_NAME.app" \
         "$HOME/Applications/$APP_NAME.app"; do
  if [ -e "$p" ]; then rm -rf "$p" && echo "    removed $p"; fi
done

echo "==> 3/6  Wiping stale permission records and saved settings…"
# Reset each service EXPLICITLY. This matters: `tccutil reset All <bundleid>`
# does NOT reliably clear the *system*-level grants (Accessibility and Screen
# Recording) — only the per-service form does. Leaving them is exactly what got
# earlier installs stuck: System Settings showed the toggle "on" (a stale entry
# bound to the old ad-hoc identity) while the running app saw it as denied, and
# only Microphone — a user-level grant — actually worked. Resetting per-service
# removes those entries so the next grant binds to the new, stable identity.
for svc in Accessibility ScreenCapture ListenEvent Microphone Camera All; do
  tccutil reset "$svc" "$BUNDLE_ID" >/dev/null 2>&1 || true
done
echo "    reset Accessibility, Screen Recording, Input Monitoring, Microphone"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && echo "    cleared saved settings" || true

echo "==> 4/6  Building a fresh, stably-signed app…"
"$ROOT/scripts/build-app.sh"

echo "==> 5/6  Installing to /Applications…"
[ -d "$BUILT" ] || { echo "build did not produce $BUILT"; exit 1; }
rm -rf "$INSTALLED"
ditto "$BUILT" "$INSTALLED"
# This is a local build, not a download — strip any quarantine/provenance xattrs
# so macOS opens it with a plain double-click (no right-click → Open dance).
xattr -cr "$INSTALLED" 2>/dev/null || true
rm -rf "$BUILT"

echo "==> 6/6  Launching LocalClicky…"
open "$INSTALLED"

echo ""
echo "  ============================================================"
echo "  ✅ Installed and launched: $INSTALLED"
echo "  ============================================================"
echo ""
echo "  LocalClicky lives in the MENU BAR (top-right of the screen),"
echo "  not the Dock. Click its icon, then:"
echo ""
echo "    1. Grant the 4 permissions it asks for (Microphone,"
echo "       Accessibility, Screen Recording, Screen Content)."
echo "    2. If macOS asks you to quit & reopen for Screen Recording,"
echo "       do it — these grants now persist across future updates."
echo "    3. Hold  Control + Option  to talk; release to send."
echo ""
echo "  These permissions will STICK from now on (the app is signed"
echo "  with a stable local identity), so you won't have to redo this"
echo "  every time it's rebuilt."
echo ""

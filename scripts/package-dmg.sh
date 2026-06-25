#!/usr/bin/env bash
#
# package-dmg.sh — wrap dist/LocalClicky.app into a drag-to-Applications DMG.
# Run scripts/build-app.sh first.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/LocalClicky.app"
DMG="$ROOT/dist/LocalClicky.dmg"

[ -d "$APP" ] || { echo "No app found. Run scripts/build-app.sh first."; exit 1; }

STAGE="$ROOT/dist/.dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "LocalClicky" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> DMG ready: $DMG"
ls -lh "$DMG" | awk '{print "    size:", $5}'

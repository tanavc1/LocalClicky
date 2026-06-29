#!/usr/bin/env bash
#
# release.sh — build LocalClicky, package the DMG, and publish (or update) the
# GitHub Release that backs the one-click download. One command for maintainers.
#
#   scripts/release.sh            # tag from Info.plist version (e.g. v1.0.1)
#   scripts/release.sh v1.2.0     # explicit tag
#
# The release always carries an asset literally named "LocalClicky.dmg", so the
# stable download URL
#   https://github.com/<repo>/releases/latest/download/LocalClicky.dmg
# (used by the README button and scripts/web-install.sh) keeps working forever.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="tanavc1/LocalClicky"
APP_NAME="LocalClicky"
DMG="$ROOT/dist/$APP_NAME.dmg"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
  "$ROOT/Sources/LocalClicky/Resources/Info.plist" 2>/dev/null || echo 1.0.0)"
TAG="${1:-v$VERSION}"

echo "==> Building app + DMG for ${TAG}…"
"$ROOT/scripts/build-app.sh"
"$ROOT/scripts/package-dmg.sh"
[ -f "$DMG" ] || { echo "DMG not found at $DMG"; exit 1; }

NOTES_FILE="$ROOT/dist/release-notes.md"
cat > "$NOTES_FILE" <<'EOF'
**One-click download:** grab `LocalClicky.dmg` below, open it, and drag LocalClicky to Applications.

Even easier (no Gatekeeper prompt):
```
curl -fsSL https://raw.githubusercontent.com/tanavc1/LocalClicky/main/scripts/web-install.sh | bash
```

LocalClicky lives in the menu bar. Grant the 3 permissions, then hold **Control + Option** to talk. Needs an Apple-silicon Mac on macOS 14.2+; the app's panel installs Ollama + the local models for you.
EOF

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "==> Updating existing release ${TAG}…"
  gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES_FILE" --latest
else
  echo "==> Creating release ${TAG}…"
  gh release create "$TAG" "$DMG" --repo "$REPO" \
    --title "$APP_NAME $TAG" --notes-file "$NOTES_FILE" --latest
fi

echo ""
echo "✅ Published. Download: https://github.com/$REPO/releases/latest/download/$APP_NAME.dmg"

#!/usr/bin/env bash
# Build DirectDrop.app and wrap it in a drag-to-Applications DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(awk '/^version:/ {print $2}' pubspec.yaml | cut -d+ -f1)}"
APP="build/macos/Build/Products/Release/DirectDrop.app"
OUT_DIR="${ROOT}/dist/macos"
DMG="${OUT_DIR}/DirectDrop-macos.dmg"

echo "[+] flutter build macos --release"
flutter pub get
flutter build macos --release

if [[ ! -d "$APP" ]]; then
  echo "missing $APP" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "DirectDrop" \
    --window-pos 200 120 \
    --window-size 640 400 \
    --icon-size 128 \
    --icon "DirectDrop.app" 160 180 \
    --hide-extension "DirectDrop.app" \
    --app-drop-link 460 180 \
    "$DMG" \
    "$APP"
else
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  ditto "$APP" "$STAGE/DirectDrop.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "DirectDrop" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi

echo "[+] DMG ready: $DMG (v$VERSION)"
ls -lh "$DMG"

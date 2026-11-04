#!/bin/bash
# Builds a release DiskLens.app into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DiskLens.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/DiskLens"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "Generating app icon…"
  TMP="$(mktemp -d)"
  swift scripts/make-icon.swift "$TMP/icon.png" >/dev/null
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskLens"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"

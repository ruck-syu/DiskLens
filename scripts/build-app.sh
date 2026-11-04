#!/bin/bash
# Builds a release DiskLens.app into ./build
#   VERSION=1.0.7 BUILD_NUMBER=7  set the bundle version (defaults: ./VERSION, 1)
#   UNIVERSAL=1                    build for both Apple silicon and Intel
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DiskLens.app"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 1.0)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/DiskLens"

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
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $VERSION" \
  -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP ($VERSION, build $BUILD_NUMBER)"

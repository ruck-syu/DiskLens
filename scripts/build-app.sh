#!/bin/bash
# Builds a release DiskLens.app into ./build
#   VERSION=1.0.7 BUILD_NUMBER=7  set the bundle version (defaults: ./VERSION, 1)
#   UNIVERSAL=1                    build for both Apple silicon and Intel
#   SIGN_IDENTITY / SIGN_KEYCHAIN  code signing identity (SHA-1) and keychain
#
# Signing with the same certificate every time keeps the app's identity stable,
# so macOS remembers permissions (Full Disk Access, folders, Automation) across
# updates. Without an identity the app is ad-hoc signed and macOS asks again
# after every build. Run scripts/setup-signing.sh once to create one.
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
SIGN_DIR="$HOME/.disklens-signing"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-$SIGN_DIR/signing.keychain-db}"
if [ -z "${SIGN_IDENTITY:-}" ] && [ -f "$SIGN_KEYCHAIN" ]; then
  if [ -f "$SIGN_DIR/keychain-password.txt" ]; then
    security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password.txt")" "$SIGN_KEYCHAIN"
  fi
  SIGN_IDENTITY="$(security find-identity -p codesigning "$SIGN_KEYCHAIN" | awk '/DiskLens Self-Signed/ {print $2; exit}')"
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP"
  echo "Signed with stable identity $SIGN_IDENTITY"
else
  echo "warning: no signing identity found; ad-hoc signing (macOS will forget permissions after each build)" >&2
  codesign --force --sign - "$APP" >/dev/null
fi

echo "Built $APP ($VERSION, build $BUILD_NUMBER)"

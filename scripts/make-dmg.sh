#!/bin/bash
# Packages build/DiskLens.app into build/DiskLens-<version>.dmg
# with a shortcut to /Applications for drag-to-install.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DiskLens.app"
[ -d "$APP" ] || { echo "Run scripts/build-app.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/DiskLens-$VERSION.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/DiskLens.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "DiskLens $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "$DMG"

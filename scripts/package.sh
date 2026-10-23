#!/bin/bash
# Packages build/Inkwell.app as a DMG (with an Applications link) and a ZIP.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Inkwell.app"
[ -d "$APP" ] || "$ROOT/scripts/bundle.sh" release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/Inkwell-$VERSION.dmg"
ZIP="$ROOT/build/Inkwell-$VERSION.zip"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Inkwell $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

rm -f "$ZIP"
(cd "$ROOT/build" && ditto -c -k --keepParent Inkwell.app "$ZIP")
shasum -a 256 "$DMG" "$ZIP"

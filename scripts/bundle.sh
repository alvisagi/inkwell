#!/bin/bash
# Builds Inkwell.app into build/. Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Inkwell.app"
VERSION="1.0.0"

if [ ! -d "$ROOT/app/Frameworks/TypstCoreFFI.xcframework" ]; then
  "$ROOT/scripts/build-core.sh"
fi

cd "$ROOT/app"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Inkwell"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Inkwell"
if [ -d "$ROOT/app/Resources" ]; then
  cp -R "$ROOT/app/Resources/." "$APP/Contents/Resources/"
fi
if [ -d "$ROOT/build/docs-site" ]; then
  cp -R "$ROOT/build/docs-site" "$APP/Contents/Resources/TypstDocs"
else
  echo "note: build/docs-site missing; run scripts/build-docs.sh for offline docs"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>zh-Hans</string><string>de</string><string>fr</string><string>es</string><string>it</string><string>nl</string><string>pt</string></array>
  <key>CFBundleDisplayName</key><string>Inkwell</string>
  <key>CFBundleExecutable</key><string>Inkwell</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>app.inkwell.editor</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Inkwell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Typst Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key><array><string>app.typst.document</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
      <key>UTTypeDescription</key><string>Typst Document</string>
      <key>UTTypeIdentifier</key><string>app.typst.document</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>typ</string></array>
        <key>public.mime-type</key><array><string>text/vnd.typst</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"

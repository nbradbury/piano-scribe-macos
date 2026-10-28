#!/bin/bash
# Builds a double-clickable PianoScribe.app into ./build (release, ad-hoc signed).
#   ./scripts/build-app.sh            # build
#   ./scripts/build-app.sh --open     # build and launch
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Building (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="build/PianoScribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PianoScribe" "$APP/Contents/MacOS/PianoScribe"
for b in "$BIN"/PianoScribe_*.bundle; do
  cp -R "$b" "$APP/Contents/Resources/"
done
cp Sources/PianoScribe/Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PianoScribe</string>
  <key>CFBundleDisplayName</key><string>PianoScribe</string>
  <key>CFBundleIdentifier</key><string>local.pianoscribe.app</string>
  <key>CFBundleExecutable</key><string>PianoScribe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Audio or Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.audiovisual-content</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign failed; the app will still run locally)"

echo "✓ Built $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi

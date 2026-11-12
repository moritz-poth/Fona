#!/bin/bash
# Builds dist/Fona.app: menu bar app (sandbox + network.client) with the FonaDecoder XPC service (sandbox, no rights).
# Universal (arm64 + x86_64), ad-hoc signed inside-out, never --deep. Usage: scripts/build-app.sh [--fast]  (--fast: arm64 debug)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=0.1.0; BUILD=1
APP=dist/Fona.app; XPC="$APP/Contents/XPCServices/FonaDecoder.xpc"
if [ "${1:-}" = "--fast" ]; then
  swift build --product Fona
  swift build --product FonaDecoder
  BIN_APP=.build/debug/Fona; BIN_XPC=.build/debug/FonaDecoder
else
  for a in arm64 x86_64; do
    swift build -c release --arch $a --product Fona
    swift build -c release --arch $a --product FonaDecoder
  done
  mkdir -p .build/universal
  lipo -create .build/arm64-apple-macosx/release/Fona .build/x86_64-apple-macosx/release/Fona -output .build/universal/Fona
  lipo -create .build/arm64-apple-macosx/release/FonaDecoder .build/x86_64-apple-macosx/release/FonaDecoder -output .build/universal/FonaDecoder
  BIN_APP=.build/universal/Fona; BIN_XPC=.build/universal/FonaDecoder
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$XPC/Contents/MacOS"
cp "$BIN_APP" "$APP/Contents/MacOS/Fona"
cp "$BIN_XPC" "$XPC/Contents/MacOS/FonaDecoder"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# icons: drawn from design/icon (rendered once to Resources/*.png)
ICONSET=$(mktemp -d)/AppIcon.iconset; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Fona</string>
  <key>CFBundleExecutable</key><string>Fona</string>
  <key>CFBundleIdentifier</key><string>io.github.moritz-poth.fona</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>FonaRelease</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
  <key>NSHumanReadableCopyright</key><string>© 2026 Moritz Poth. GPL-3.0-or-later.</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cat > "$XPC/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FonaDecoder</string>
  <key>CFBundleExecutable</key><string>FonaDecoder</string>
  <key>CFBundleIdentifier</key><string>io.github.moritz-poth.fona.decoder</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST
codesign --force --sign - --options runtime --entitlements Entitlements/FonaDecoder.entitlements "$XPC"
codesign --force --sign - --options runtime --entitlements Entitlements/Fona.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP ($VERSION)"

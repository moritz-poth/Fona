#!/bin/bash
# Builds dist/Fona.app: menu bar app (sandbox + network.client) with the FonaDecoder XPC service (sandbox, no rights).
# Universal (arm64 + x86_64), ad-hoc signed inside-out, never --deep. Usage: scripts/build-app.sh [--fast]  (--fast: arm64 debug)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.1.0}          # CFBundleShortVersionString (numbers only)
RELEASE=${RELEASE:-0.1.0}          # tag v$RELEASE and zip name Fona-$RELEASE.zip (e.g. 0.2.0-beta.1)
BUILD=1
APP=dist/Fona.app; XPC="$APP/Contents/XPCServices/FonaDecoder.xpc"; HELPER="$APP/Contents/Helpers/FonaUpdater.app"
if [ "${1:-}" = "--fast" ]; then
  swift build --product Fona
  swift build --product FonaDecoder
  swift build --product FonaUpdater
  BIN_APP=.build/debug/Fona; BIN_XPC=.build/debug/FonaDecoder; BIN_UPD=.build/debug/FonaUpdater
else
  for a in arm64 x86_64; do
    swift build -c release --arch $a --product Fona
    swift build -c release --arch $a --product FonaDecoder
    swift build -c release --arch $a --product FonaUpdater
  done
  mkdir -p .build/universal
  lipo -create .build/arm64-apple-macosx/release/Fona .build/x86_64-apple-macosx/release/Fona -output .build/universal/Fona
  lipo -create .build/arm64-apple-macosx/release/FonaDecoder .build/x86_64-apple-macosx/release/FonaDecoder -output .build/universal/FonaDecoder
  lipo -create .build/arm64-apple-macosx/release/FonaUpdater .build/x86_64-apple-macosx/release/FonaUpdater -output .build/universal/FonaUpdater
  BIN_APP=.build/universal/Fona; BIN_XPC=.build/universal/FonaDecoder; BIN_UPD=.build/universal/FonaUpdater
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$XPC/Contents/MacOS" "$HELPER/Contents/MacOS"
cp "$BIN_APP" "$APP/Contents/MacOS/Fona"
cp "$BIN_XPC" "$XPC/Contents/MacOS/FonaDecoder"
cp "$BIN_UPD" "$HELPER/Contents/MacOS/FonaUpdater"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# icons: drawn from design/icon (rendered once to Resources/*.png)
ICONSET=$(mktemp -d)/AppIcon.iconset; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/"
cp -R Resources/help "$APP/Contents/Resources/help"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Fona</string>
  <key>CFBundleExecutable</key><string>Fona</string>
  <key>CFBundleIdentifier</key><string>io.github.moritz-poth.fona</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>FonaRelease</key><string>$RELEASE</string>
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
cat > "$HELPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FonaUpdater</string>
  <key>CFBundleExecutable</key><string>FonaUpdater</string>
  <key>CFBundleIdentifier</key><string>io.github.moritz-poth.fona.updater</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
# signed inside-out, never --deep: decoder (sandbox, no rights), updater (no sandbox, hardened runtime), app (sandbox)
codesign --force --sign - --options runtime --entitlements Entitlements/FonaDecoder.entitlements "$XPC"
codesign --force --sign - --options runtime "$HELPER"
codesign --force --sign - --options runtime --entitlements Entitlements/Fona.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP ($RELEASE)"
if [ "${1:-}" != "--fast" ]; then
  # updater zip + Ed25519 signature (only if the Keychain key matches the public key in the app)
  rm -f "dist/Fona-$RELEASE.zip" "dist/Fona-$RELEASE.zip.sig"
  ditto -c -k --keepParent "$APP" "dist/Fona-$RELEASE.zip"
  # download image: the shared moe-apps DMG window (660 × 400, split background, motion trail); the updater keeps
  # using the zip. create-dmg arranges the window through the Finder (needs Finder automation once).
  DMG="dist/Fona-$RELEASE.dmg"
  # never touch someone else's volume: the Finder's disk "Fona" below must be ours
  if ls /Volumes | grep -Eq '^Fona( [0-9]+)?$'; then echo "a volume \"Fona\" is mounted – eject it first" >&2; exit 1; fi
  STAGE=.build/dmg-stage
  rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Fona.app"
  swift scripts/make-dmg-background.swift Resources/AppIcon-1024.png .build/dmg-bg.png 1
  swift scripts/make-dmg-background.swift Resources/AppIcon-1024.png .build/dmg-bg@2x.png 2
  tiffutil -cathidpicheck .build/dmg-bg.png .build/dmg-bg@2x.png -out .build/dmg-background.tiff 2>/dev/null
  create-dmg --volname Fona --window-size 660 400 --icon-size 128 \
    --icon "Fona.app" 170 188 --app-drop-link 490 188 --hide-extension "Fona.app" \
    --background .build/dmg-background.tiff --no-internet-enable "$DMG" "$STAGE" >/dev/null
  rm -rf "$STAGE"
  KEY=$(swift scripts/update-key.swift public 2>/dev/null || true)
  if [ -n "$KEY" ] && grep -q "$KEY" Sources/FonaCore/Update/UpdateCheck.swift; then
    swift scripts/update-key.swift sign "dist/Fona-$RELEASE.zip" && echo "signed dist/Fona-$RELEASE.zip"
  else
    echo "NOT SIGNED: the Keychain key does not match UpdateKey.publicKey" >&2
  fi
fi

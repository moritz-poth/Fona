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
  # download image: the classic window with the app next to an Applications link (the updater keeps using the zip)
  DMG="dist/Fona-$RELEASE.dmg"
  STAGE=.build/dmg; RW=.build/Fona-rw.dmg
  rm -rf "$STAGE" "$RW" "$DMG"; mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Fona.app"
  ln -s /Applications "$STAGE/Applications"
  mkdir "$STAGE/.background"
  swift scripts/make-dmg-background.swift .build/dmg-bg.png 1
  swift scripts/make-dmg-background.swift .build/dmg-bg@2x.png 2
  tiffutil -cathidpicheck .build/dmg-bg.png .build/dmg-bg@2x.png -out "$STAGE/.background/background.tiff" 2>/dev/null
  # never eject someone else's volume, and Finder's disk "Fona" below must be ours: no other volume of that name
  if ls /Volumes | grep -Eq '^Fona( [0-9]+)?$'; then echo "a volume \"Fona\" is mounted – eject it first" >&2; exit 1; fi
  hdiutil create -quiet -volname Fona -srcfolder "$STAGE" -fs HFS+ -format UDRW "$RW"
  hdiutil attach -quiet -noautoopen -mountpoint "/Volumes/Fona" "$RW"
  # window layout is stored by Finder in .DS_Store (needs Finder automation for the terminal once)
  osascript <<'OSA' || echo "warning: DMG window layout not set (Finder automation denied?)" >&2
  tell application "Finder"
    repeat 20 times -- Finder sees a fresh image only after a moment
      if exists disk "Fona" then exit repeat
      delay 0.5
    end repeat
    tell disk "Fona"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set opts to icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 128
      set background picture of opts to file ".background:background.tiff"
      set position of item "Fona.app" of container window to {140, 160}
      set position of item "Applications" of container window to {400, 160}
      set bounds of container window to {200, 120, 740, 460}
      update without registering applications
      delay 2
      close
      -- Finder writes the window size to .DS_Store only reliably after a second open/close
      open
      delay 1
      close
    end tell
  end tell
OSA
  sync
  # Finder or Spotlight may still hold the volume for a moment
  hdiutil detach "/Volumes/Fona" -quiet || { sleep 2; hdiutil detach "/Volumes/Fona" -quiet -force; }
  hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
  rm -rf "$STAGE" "$RW"
  KEY=$(swift scripts/update-key.swift public 2>/dev/null || true)
  if [ -n "$KEY" ] && grep -q "$KEY" Sources/FonaCore/Update/UpdateCheck.swift; then
    swift scripts/update-key.swift sign "dist/Fona-$RELEASE.zip" && echo "signed dist/Fona-$RELEASE.zip"
  else
    echo "NOT SIGNED: the Keychain key does not match UpdateKey.publicKey" >&2
  fi
fi

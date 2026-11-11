#!/bin/bash
# P0-a: builds FonaSpike.app (sandboxed) with embedded FonaSpikeUpdater.app (not sandboxed), ad-hoc, inside-out.
# Usage: build.sh <version> <out dir>   e.g. build.sh v1 out/v1
set -euo pipefail
cd "$(dirname "$0")"
V=$1; OUT=$2; APP="$OUT/FonaSpike.app"; HELP="$APP/Contents/Helpers/FonaSpikeUpdater.app"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$HELP/Contents/MacOS"
echo "let SPIKE_VERSION = \"$V\"" > /tmp/fona-spike-version.swift
mkdir -p /tmp/fona-spike-src && cp App.swift /tmp/fona-spike-src/main.swift && swiftc -O -o "$APP/Contents/MacOS/FonaSpike" /tmp/fona-spike-src/main.swift /tmp/fona-spike-version.swift
swiftc -O -o "$HELP/Contents/MacOS/FonaSpikeUpdater" Updater.swift
plist() { cat <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$1</string><key>CFBundleExecutable</key><string>$1</string>
<key>CFBundleIdentifier</key><string>$2</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
P
}
plist FonaSpike io.github.moritz-poth.fona.spike > "$APP/Contents/Info.plist"
plist FonaSpikeUpdater io.github.moritz-poth.fona.spike.updater > "$HELP/Contents/Info.plist"
cat > /tmp/fona-spike.entitlements <<'E'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
E
codesign --force --sign - --options runtime "$HELP"
codesign --force --sign - --options runtime --entitlements /tmp/fona-spike.entitlements "$APP"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "CDHash=|Identifier="

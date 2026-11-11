#!/bin/bash
# P0-g: FonaSpikeHost.app (sandbox + network.client) with Contents/XPCServices/FonaDecoder.xpc (sandbox, no rights).
set -euo pipefail
cd "$(dirname "$0")"
OUT=out; APP="$OUT/FonaSpikeHost.app"; XPC="$APP/Contents/XPCServices/FonaDecoder.xpc"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$XPC/Contents/MacOS" /tmp/p0g-src
cp Host.swift /tmp/p0g-src/main.swift && swiftc -O -o "$APP/Contents/MacOS/FonaSpikeHost" /tmp/p0g-src/main.swift Shared.swift
cp Service.swift /tmp/p0g-src/svc-main.swift && mkdir -p /tmp/p0g-svc && cp Service.swift /tmp/p0g-svc/main.swift && \
  swiftc -O -o "$XPC/Contents/MacOS/FonaDecoder" /tmp/p0g-svc/main.swift Shared.swift
cp test.adts "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>FonaSpikeHost</string><key>CFBundleExecutable</key><string>FonaSpikeHost</string>
<key>CFBundleIdentifier</key><string>io.github.moritz-poth.fona.spike.host</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
P
cat > "$XPC/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>FonaDecoder</string><key>CFBundleExecutable</key><string>FonaDecoder</string>
<key>CFBundleIdentifier</key><string>io.github.moritz-poth.fona.spike.decoder</string><key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
P
ent() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>%s</dict></plist>\n' "$1"; }
ent '<key>com.apple.security.app-sandbox</key><true/>' > /tmp/p0g-xpc.entitlements
ent '<key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.network.client</key><true/>' > /tmp/p0g-host.entitlements
codesign --force --sign - --options runtime --entitlements /tmp/p0g-xpc.entitlements "$XPC"
codesign --force --sign - --options runtime --entitlements /tmp/p0g-host.entitlements "$APP"
codesign --verify --deep --strict "$APP" && echo signed

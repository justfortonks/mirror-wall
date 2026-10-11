#!/bin/bash
# Builds MirrorWall.app (release, ad-hoc signed) in the repository folder.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MirrorWall"

APP=MirrorWall.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MirrorWall"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Mirror Wall</string>
    <key>CFBundleDisplayName</key><string>Mirror Wall</string>
    <key>CFBundleIdentifier</key><string>com.justfortonks.mirrorwall</string>
    <key>CFBundleExecutable</key><string>MirrorWall</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Mirror Wall listens for iPhones on your network so they can mirror their screens to this Mac.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_airplay._tcp</string>
        <string>_raop._tcp</string>
    </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"

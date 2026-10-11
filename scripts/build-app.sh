#!/bin/bash
# Builds MirrorWall.app (release, ad-hoc signed) in the repository folder.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MirrorWall"

APP=MirrorWall.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MirrorWall"

# App icon: every size macOS asks for, from the 1024-pixel PNG.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Sources/MirrorWall/Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Sources/MirrorWall/Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Mirror Wall</string>
    <key>CFBundleDisplayName</key><string>Mirror Wall</string>
    <key>CFBundleIdentifier</key><string>com.justfortonks.mirrorwall</string>
    <key>CFBundleExecutable</key><string>MirrorWall</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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

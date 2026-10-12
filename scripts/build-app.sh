#!/bin/bash
# Builds MirrorWall.app (release, ad-hoc signed) in the repository folder, with its own uxplay
# and GStreamer inside so it can be copied to another Mac.
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

# Version: the number of commits, so every build from newer code has a higher one (0.61, 0.62…),
# plus the commit itself and the build date, shown in Mirror Wall › About Mirror Wall.
BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then COMMIT="$COMMIT with local changes"; fi
BUILT=$(date "+%Y-%m-%d %H:%M")
cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>0.$BUILD</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>MirrorWallCommit</key><string>$COMMIT</string>
    <key>MirrorWallBuilt</key><string>$BUILT</string>
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

# The receiver: a uxplay that brings its own GStreamer, so the app runs on a Mac with nothing
# else installed. Set UXPLAY to the uxplay to package; otherwise the usual places are tried.
UXPLAY="${UXPLAY:-}"
if [ -z "$UXPLAY" ]; then
    for candidate in /opt/homebrew/bin/uxplay /usr/local/bin/uxplay ../UxPlay/build/uxplay "$HOME/Documents/Claude Code/casting app/UxPlay/build/uxplay"; do
        if [ -x "$candidate" ]; then
            UXPLAY="$candidate"
            break
        fi
    done
fi
if [ -n "$UXPLAY" ]; then
    scripts/bundle-receiver.py "$UXPLAY" "$APP/Contents/Resources/receiver"
else
    echo "warning: no uxplay found to package (set UXPLAY=/path/to/uxplay)." >&2
    echo "         The app will look for a uxplay on the Mac it runs on instead." >&2
fi

codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $(pwd)/$APP"

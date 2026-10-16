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

# Branded branding: Barlow (OFL) and, if it's been added locally, the logo. Brand.swift looks
# for these in Contents/Resources/Brand.
cp -R Sources/MirrorWall/Resources/Brand "$APP/Contents/Resources/Brand"

# Version: the number of commits, so every build from newer code has a higher one (0.61, 0.62…),
# plus the commit itself and the build date, shown in Mirror Wall › About Mirror Wall.
BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse --short HEAD)
COMMIT_FULL=$(git rev-parse HEAD)
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then COMMIT="$COMMIT with local changes"; fi
BUILT=$(date "+%Y-%m-%d %H:%M")
# A beta (a test build published as a pre-release by the Release workflow) also carries its beta
# number, so Check for Update can tell 0.112 beta 7 from beta 8 and from the 0.112 release.
BETA="${MIRRORWALL_BETA:-}"
VERSION="0.$BUILD${BETA:+ beta $BETA}"
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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>MirrorWallCommit</key><string>$COMMIT</string>
    <key>MirrorWallCommitFull</key><string>$COMMIT_FULL</string>
    <key>MirrorWallBuilt</key><string>$BUILT</string>
${BETA:+    <key>MirrorWallBeta</key><string>$BETA</string>
}    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Mirror Wall listens for iPhones and Android phones on your network so they can mirror their screens to this Mac.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_airplay._tcp</string>
        <string>_raop._tcp</string>
        <string>_mirrorwall._tcp</string>
    </array>
</dict>
</plist>
PLIST

# The receiver: a uxplay that brings its own GStreamer, so the app runs on a Mac with nothing
# else installed. Set UXPLAY to the uxplay to package; otherwise the usual places are tried,
# starting with the one scripts/build-uxplay.sh builds (what releases use).
UXPLAY="${UXPLAY:-}"
if [ -z "$UXPLAY" ]; then
    for candidate in build/UxPlay/build/uxplay /opt/homebrew/bin/uxplay /usr/local/bin/uxplay ../UxPlay/build/uxplay "$HOME/Documents/Claude Code/casting app/UxPlay/build/uxplay"; do
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

# The OBS feed's Syphon framework, if the app was built with it (scripts/build-syphon.sh).
SYPHON=$(find Vendor/Syphon.xcframework -maxdepth 2 -name Syphon.framework -type d 2>/dev/null | head -1)
if [ -n "$SYPHON" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SYPHON" "$APP/Contents/Frameworks/"
    codesign --force --sign - "$APP/Contents/Frameworks/Syphon.framework"
fi

# Licences: Mirror Wall's own (GPLv3, as UxPlay's), and the notices of what it bundles.
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# What's new, shown in About Mirror Wall.
cp CHANGELOG.md "$APP/Contents/Resources/"
if [ -n "$SYPHON" ] && [ -f build/Syphon-Framework/License.txt ]; then
    mkdir -p "$APP/Contents/Resources/licenses/syphon"
    cp build/Syphon-Framework/License.txt "$APP/Contents/Resources/licenses/syphon/"
fi

codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $(pwd)/$APP"

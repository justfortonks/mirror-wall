#!/bin/bash
# Builds MirrorWall.app and packs it into MirrorWall.dmg, a disk image to copy to another Mac:
# open it there and drag Mirror Wall to Applications. With a Developer ID certificate and
# notarytool credentials on this Mac (scripts/notarize.sh), the app and the DMG are notarized
# and stapled, so the other Mac opens them without a warning.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
if [ ! -x MirrorWall.app/Contents/Resources/receiver/bin/uxplay ]; then
    echo "error: MirrorWall.app has no uxplay inside, so it wouldn't work on another Mac." >&2
    exit 1
fi

scripts/notarize.sh MirrorWall.app

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R MirrorWall.app "$STAGING/Mirror Wall.app"
ln -s /Applications "$STAGING/Applications"
cp THIRD_PARTY_NOTICES.md "$STAGING/Licenses and Source Code.txt"

rm -f MirrorWall.dmg
hdiutil create -quiet -volname "Mirror Wall" -srcfolder "$STAGING" -format UDZO MirrorWall.dmg
IDENTITY="${MIRRORWALL_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" MirrorWall.dmg
    scripts/notarize.sh MirrorWall.dmg
fi
echo "Built $(pwd)/MirrorWall.dmg ($(du -h MirrorWall.dmg | cut -f1 | tr -d ' '))"

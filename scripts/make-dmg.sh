#!/bin/bash
# Builds MirrorWall.app and packs it into MirrorWall.dmg, a disk image to copy to another Mac:
# open it there and drag Mirror Wall to Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
if [ ! -x MirrorWall.app/Contents/Resources/receiver/bin/uxplay ]; then
    echo "error: MirrorWall.app has no uxplay inside, so it wouldn't work on another Mac." >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R MirrorWall.app "$STAGING/Mirror Wall.app"
ln -s /Applications "$STAGING/Applications"
cp THIRD_PARTY_NOTICES.md "$STAGING/Licenses and Source Code.txt"

rm -f MirrorWall.dmg
hdiutil create -quiet -volname "Mirror Wall" -srcfolder "$STAGING" -format UDZO MirrorWall.dmg
echo "Built $(pwd)/MirrorWall.dmg ($(du -h MirrorWall.dmg | cut -f1 | tr -d ' '))"

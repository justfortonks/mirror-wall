#!/bin/bash
# A DMG for a few trusted testers: like scripts/make-dmg.sh, but Mirror Wall comes with the relay
# set up, using the guest token (keychain item "Mirror Wall Relay guest token", also in the
# relay's RELAY_GUEST_TOKENS secret). The token can be read out of the app, so only give this to
# people you'd give the token to. Withdraw it with:
#   flyctl secrets unset -a mirror-wall-relay RELAY_GUEST_TOKENS
set -euo pipefail
cd "$(dirname "$0")/.."
export MIRRORWALL_BUNDLED_RELAY_HOST="${MIRRORWALL_BUNDLED_RELAY_HOST:-mirror-wall-relay.fly.dev}"
export MIRRORWALL_BUNDLED_RELAY_TOKEN="$(security find-generic-password -a mirrorwall -s "Mirror Wall Relay guest token" -w)"
scripts/make-dmg.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" MirrorWall.app/Contents/Info.plist)
mv MirrorWall.dmg "MirrorWall-$VERSION-tester.dmg"
echo "Built MirrorWall-$VERSION-tester.dmg (relay set up for testers)"

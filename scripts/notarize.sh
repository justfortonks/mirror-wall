#!/bin/bash
# Notarizes a signed MirrorWall.app or MirrorWall.dmg with Apple and staples the ticket, so
# Gatekeeper opens it without a warning even offline. Needs credentials stored once with:
#   xcrun notarytool store-credentials mirrorwall --apple-id <Apple ID> --team-id <team ID>
# (the profile name can be changed with MIRRORWALL_NOTARY_PROFILE).
set -euo pipefail
TARGET="${1:?usage: notarize.sh MirrorWall.app|MirrorWall.dmg}"
PROFILE="${MIRRORWALL_NOTARY_PROFILE:-mirrorwall}"
# CI stores the profile in a temporary keychain; notarytool needs to be told which one.
KEYCHAIN_ARGS=()
if [ -n "${MIRRORWALL_NOTARY_KEYCHAIN:-}" ]; then KEYCHAIN_ARGS=(--keychain "$MIRRORWALL_NOTARY_KEYCHAIN"); fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} >/dev/null 2>&1; then
    echo "notarize: no notarytool credentials under profile '$PROFILE'; skipping (the app stays signed but unnotarized)." >&2
    exit 0
fi

SUBMIT="$TARGET"
if [ -d "$TARGET" ]; then
    SUBMIT="$(mktemp -d)/$(basename "$TARGET" .app).zip"
    ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi
echo "notarize: submitting $(basename "$TARGET")…"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --wait --timeout 30m | tee /tmp/notarize.log
if ! grep -q 'status: Accepted' /tmp/notarize.log; then
    ID=$(grep -m1 '  id:' /tmp/notarize.log | awk '{print $2}')
    [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} || true
    echo "notarize: Apple rejected $(basename "$TARGET"); see the log above." >&2
    exit 1
fi
xcrun stapler staple "$TARGET"
if [ -d "$TARGET" ]; then spctl --assess --type execute --verbose=2 "$TARGET"; fi
echo "notarize: $(basename "$TARGET") is notarized and stapled"

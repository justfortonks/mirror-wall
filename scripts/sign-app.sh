#!/bin/bash
# Signs MirrorWall.app (or the app given) for distribution: every dylib, GStreamer plugin and
# executable inside it first, then the app, with the hardened runtime and a secure timestamp, so
# notarization accepts it and Gatekeeper opens it on any Mac.
#
# The identity: MIRRORWALL_SIGNING_IDENTITY if set, else the one "Developer ID Application"
# certificate in the keychain. With none, the app is ad-hoc signed as before (fine on the Mac
# that built it; other Macs ask to right-click › Open).
set -euo pipefail
APP="${1:-MirrorWall.app}"
cd "$(dirname "$0")/.."

IDENTITY="${MIRRORWALL_SIGNING_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
fi
if [ -z "$IDENTITY" ]; then
    echo "sign-app: no Developer ID certificate found; ad-hoc signing $APP" >&2
    codesign --force --deep --sign - "$APP"
    codesign --verify --strict "$APP"
    exit 0
fi
echo "sign-app: signing $APP as $IDENTITY"

# The receiver runs GStreamer, whose ORC library generates machine code at run time; the hardened
# runtime needs this entitlement to allow that. The app itself needs none.
RECEIVER_ENTITLEMENTS="$(mktemp -t mirrorwall-entitlements).plist"
cat > "$RECEIVER_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
PLIST

sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }

# Inside out: libraries and plugins, then the executables that load them, then frameworks, then
# the app. Mach-O files are found by content, not name, so nothing in the receiver is missed.
RECEIVER="$APP/Contents/Resources/receiver"
if [ -d "$RECEIVER" ]; then
    find "$RECEIVER" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 | while IFS= read -r -d '' f; do sign "$f"; done
    for exe in "$RECEIVER"/libexec/* "$RECEIVER"/bin/*; do
        [ -f "$exe" ] || continue
        if file "$exe" | grep -q 'Mach-O'; then sign --entitlements "$RECEIVER_ENTITLEMENTS" "$exe"; fi
    done
fi
for fw in "$APP"/Contents/Frameworks/*.framework; do
    [ -d "$fw" ] && sign "$fw"
done
sign "$APP"
rm -f "$RECEIVER_ENTITLEMENTS"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
echo "sign-app: signed $APP"

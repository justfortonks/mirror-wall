#!/bin/bash
# Builds Mirror Wall Cast for Android signed with the release key, on the Mac that holds it.
# The key lives in ~/Library/Application Support/MirrorWall/keys/mirrorwallcast-release.jks
# and its password in the login keychain ("Mirror Wall Android key"). CI signs with the same
# key from the ANDROID_* repository secrets.
#
#   scripts/build-android-release.sh      -> android/app/build/outputs/apk/release/*.apk
set -euo pipefail
cd "$(dirname "$0")/.."

KEY="$HOME/Library/Application Support/MirrorWall/keys/mirrorwallcast-release.jks"
[ -f "$KEY" ] || { echo "No release key at $KEY" >&2; exit 1; }
PW=$(security find-generic-password -a mirrorwall -s "Mirror Wall Android key" -w)

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export MIRROR_WALL_BUILD="${MIRROR_WALL_BUILD:-$(git rev-list --count HEAD)}"
export ANDROID_KEYSTORE_PATH="$KEY" ANDROID_KEYSTORE_PASSWORD="$PW" ANDROID_KEY_ALIAS=mirrorwallcast ANDROID_KEY_PASSWORD="$PW"

(cd android && ./gradlew -q assembleRelease)
APK=android/app/build/outputs/apk/release/app-release.apk
OUT="android/app/build/outputs/apk/release/MirrorWallCast-0.$MIRROR_WALL_BUILD.apk"
cp "$APK" "$OUT"
APKSIGNER=$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail -1)apksigner
"$APKSIGNER" verify --print-certs "$OUT" | grep -m1 SHA-256
echo "$OUT"

#!/bin/bash
# Archives Mirror Wall Cast for iPhone and uploads it to App Store Connect, for TestFlight.
# Needs Xcode signed in to the Apple developer account (Xcode › Settings › Accounts); Xcode
# makes the Apple Distribution certificate and the App Store profiles itself.
# The build number is the repository's commit count, like the Mac and Android apps.
set -euo pipefail
cd "$(dirname "$0")/../ios"

BUILD=$(git rev-list --count HEAD)
ARCHIVE="$HOME/Library/Caches/MirrorWall/MirrorWallCast-$BUILD.xcarchive"

xcodegen -q
xcodebuild -project MirrorWallCast.xcodeproj -scheme MirrorWallCast -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -derivedDataPath "$HOME/Library/Caches/MirrorWall/ios-dd" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive -quiet
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions.plist \
  -exportPath "$HOME/Library/Caches/MirrorWall/ios-export" -allowProvisioningUpdates
echo "Uploaded build $BUILD. It shows in App Store Connect › TestFlight in about 10 minutes."

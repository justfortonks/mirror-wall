#!/bin/bash
# Builds Vendor/Syphon.xcframework from the Syphon project's source, for the OBS feed.
# Syphon (BSD licence) lets apps share video frames with OBS's built-in "Syphon Client" source.
# Needs Xcode with its Metal Toolchain (xcodebuild -downloadComponent MetalToolchain), because
# Syphon compiles a small Metal shader. Run it once; Package.swift picks the result up.
set -euo pipefail
cd "$(dirname "$0")/.."

COMMIT=f4761677a45b8034a3c2069ec0f3d2553da81fba # Syphon 5, September 2026
SRC=build/Syphon-Framework
if [ ! -d "$SRC/.git" ]; then
    git clone https://github.com/Syphon/Syphon-Framework.git "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$COMMIT" || true
git -C "$SRC" checkout --quiet "$COMMIT"

OUT="$(pwd)/build/syphon-release"
xcodebuild build -quiet \
    -project "$SRC/Syphon.xcodeproj" -scheme Syphon -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/syphon-derived \
    CONFIGURATION_BUILD_DIR="$OUT" MACOSX_DEPLOYMENT_TARGET=14.0

rm -rf Vendor/Syphon.xcframework
mkdir -p Vendor
xcodebuild -create-xcframework -framework "$OUT/Syphon.framework" -output Vendor/Syphon.xcframework
echo "Built $(pwd)/Vendor/Syphon.xcframework"

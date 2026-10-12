#!/bin/bash
# Builds the receiver Mirror Wall packages: UxPlay at a fixed commit with patches/*.patch applied,
# into build/UxPlay/build/uxplay. Needs Homebrew's cmake, pkgconf, libplist, openssl@3 and
# gstreamer (brew install cmake pkgconf libplist openssl@3 gstreamer).
#
# UxPlay is GPLv3: anyone given a Mirror Wall app must be able to get this source. The release
# workflow attaches it to each release as UxPlay-source-<commit>.tar.gz (made by --source-archive).
set -euo pipefail
cd "$(dirname "$0")/.."

COMMIT=ec203121355220dd90278a369eeabb0b8ba4f14a # UxPlay 1.74+, October 2026
SRC=build/UxPlay

if [ ! -d "$SRC/.git" ]; then
    git init --quiet "$SRC"
    git -C "$SRC" remote add origin https://github.com/FDH2/UxPlay.git
fi
git -C "$SRC" fetch --quiet --depth 1 origin "$COMMIT"
git -C "$SRC" checkout --quiet --force "$COMMIT"
git -C "$SRC" clean --quiet -fdx --exclude=/build
for patch in patches/*.patch; do
    git -C "$SRC" apply "$(pwd)/$patch"
done

if [ "${1:-}" = "--source-archive" ]; then
    OUT="$(pwd)/build/UxPlay-source-${COMMIT:0:12}.tar.gz"
    cp patches/*.patch "$SRC/"
    tar -czf "$OUT" -C build --exclude=.git --exclude=UxPlay/build UxPlay
    rm "$SRC"/*.patch
    echo "Wrote $OUT"
    exit 0
fi

cmake -S "$SRC" -B "$SRC/build"
cmake --build "$SRC/build" -j "$(sysctl -n hw.ncpu)"
echo "Built $(pwd)/$SRC/build/uxplay"

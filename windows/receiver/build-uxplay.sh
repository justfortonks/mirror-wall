#!/bin/bash
# Builds uxplay.exe for Mirror Wall on Windows, in an MSYS2 UCRT64 shell, and packages it with
# the parts of GStreamer it needs into windows/receiver/out:
#
#     out/uxplay.exe, out/gst-plugin-scanner.exe, out/*.dll   (uxplay and every library it loads)
#     out/lib/gstreamer-1.0/*.dll                            (plugins)
#
# The app runs that uxplay with GStreamer pointed at those plugins alone, so the PC needs nothing
# else installed. It uses the same UxPlay commit and patches as the Mac build, plus
# uxplay-windows.patch.
#
# Needs these UCRT64 packages: cmake gcc ninja libplist gstreamer gst-plugins-base
# gst-plugins-good gst-plugins-bad gst-libav openssl, and git.
set -euo pipefail

# The commit the Mac's uxplay was built from (UxPlay 1.74).
UXPLAY_COMMIT=ec203121355220dd90278a369eeabb0b8ba4f14a

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$here/work"
out="$here/out"
rm -rf "$work" "$out"
mkdir -p "$work" "$out/lib/gstreamer-1.0"

git init -q "$work/UxPlay"
cd "$work/UxPlay"
git remote add origin https://github.com/FDH2/UxPlay.git
git fetch -q --depth 1 origin "$UXPLAY_COMMIT"
git checkout -q FETCH_HEAD

for patch in uxplay-latency-report uxplay-frame-timestamps uxplay-quiet-crash; do
    git apply "$repo/patches/$patch.patch"
done
git apply "$here/uxplay-windows.patch"

mkdir build
cd build
cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja
cp uxplay.exe "$out/"

# What Mirror Wall's pipeline uses (appsrc ! queue ! h264parse ! rtph264pay ! udpsink, or the
# h265 versions), and what uxplay refuses to start without, even with audio off and its own video
# window unused. The same list as scripts/bundle-receiver.py on the Mac.
plugins=(app coreelements videoparsersbad rtp udp libav playback autodetect)
for name in "${plugins[@]}"; do
    cp "/ucrt64/lib/gstreamer-1.0/libgst$name.dll" "$out/lib/gstreamer-1.0/"
done
cp /ucrt64/libexec/gstreamer-1.0/gst-plugin-scanner.exe "$out/"

# Every library those load, from MSYS2's folder. Windows finds them next to uxplay.exe.
for file in "$out"/*.exe "$out"/lib/gstreamer-1.0/*.dll; do
    ldd "$file" | awk '{print $3}' | grep -i '^/ucrt64/' || true
done | sort -u | while read -r library; do
    cp -n "$library" "$out/"
done

# Licences: UxPlay is GPLv3, GStreamer LGPL.
cp "$work/UxPlay/LICENSE" "$out/UxPlay-LICENSE.txt"
echo "UxPlay $UXPLAY_COMMIT with Mirror Wall's patches" > "$out/VERSION.txt"

count=$(ls "$out"/*.dll | wc -l)
size=$(du -sm "$out" | cut -f1)
echo "Packaged uxplay with ${#plugins[@]} plugins and $count libraries (${size} MB) in $out"

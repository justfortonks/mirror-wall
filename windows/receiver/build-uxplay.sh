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

for patch in uxplay-latency-report uxplay-frame-timestamps uxplay-quiet-crash uxplay-stuck-stop-flag; do
    git apply "$repo/patches/$patch.patch"
done
git apply "$here/uxplay-windows.patch"

mkdir build
cd build
# NO_MARCH_NATIVE: UxPlay otherwise compiles for the build machine's own processor, and a
# receiver built on one GitHub runner then crashed (illegal instruction) on another, as it
# would on PCs with older processors.
cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DNO_MARCH_NATIVE=ON
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

# FFmpeg, which the app itself decodes and records with (gst-libav already needs most of it).
for name in avcodec avformat avutil swscale swresample; do
    cp /ucrt64/bin/$name-[0-9]*.dll "$out/"
done

# Every library those load, from MSYS2's folder. Windows finds them next to uxplay.exe.
for file in "$out"/*.exe "$out"/*.dll "$out"/lib/gstreamer-1.0/*.dll; do
    ldd "$file" | awk '{print $3}' | grep -i '^/ucrt64/' || true
done | sort -u | while read -r library; do
    cp -n "$library" "$out/"
done

# Licences: UxPlay is GPLv3, GStreamer LGPL. licenses/packages.txt lists the MSYS2 package (and
# version) each bundled file came from, and each package's licence files are copied beside it.
cp "$work/UxPlay/LICENSE" "$out/UxPlay-LICENSE.txt"
mkdir -p "$out/licenses"
for file in "$out"/*.exe "$out"/*.dll "$out"/lib/gstreamer-1.0/*.dll; do
    name=$(basename "$file")
    for dir in /ucrt64/bin /ucrt64/lib/gstreamer-1.0 /ucrt64/libexec/gstreamer-1.0; do
        if [ -f "$dir/$name" ]; then
            pacman -Qo "$dir/$name" 2>/dev/null | awk '{print $(NF-1), $NF}'
            break
        fi
    done
done | sort -u > "$out/licenses/packages.txt"
while read -r package version; do
    licenses="/ucrt64/share/licenses/${package#mingw-w64-ucrt-x86_64-}"
    if [ -d "$licenses" ]; then
        cp -r "$licenses" "$out/licenses/"
    fi
done < "$out/licenses/packages.txt"
echo "Licences for $(wc -l < "$out/licenses/packages.txt") MSYS2 packages in $out/licenses"
echo "UxPlay $UXPLAY_COMMIT with Mirror Wall's patches" > "$out/VERSION.txt"

count=$(ls "$out"/*.dll | wc -l)
size=$(du -sm "$out" | cut -f1)
ls "$out" | grep -E '^(avcodec|avformat|avutil|swscale|swresample)-'
echo "Packaged uxplay with ${#plugins[@]} plugins and $count libraries (${size} MB) in $out"

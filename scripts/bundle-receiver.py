#!/usr/bin/env python3
"""Makes a uxplay that runs on a Mac with nothing else installed.

Copies uxplay, the GStreamer plugins it needs, GStreamer's plugin scanner and every non-system
library they load into one folder, rewrites their load paths to point at each other instead of
at Homebrew, and re-signs them (ad hoc):

    <out>/bin/uxplay
    <out>/lib/*.dylib
    <out>/lib/gstreamer-1.0/*.dylib
    <out>/libexec/gst-plugin-scanner

Usage: bundle-receiver.py <path to uxplay> <output folder>

The result runs on the same architecture and macOS version (or later) as the libraries it was
made from. Run it with GST_PLUGIN_SYSTEM_PATH and GST_PLUGIN_SCANNER pointing into the folder;
the app does that (see PackagedReceiver).
"""
import os
import re
import shutil
import subprocess
import sys

# What Mirror Wall's pipeline uses (appsrc ! queue ! h264parse ! rtph264pay ! udpsink, or the h265 versions) ...
USED = ["app", "coreelements", "videoparsersbad", "rtp", "udp"]
# ... and what uxplay refuses to start without, even with audio off and its own video window unused.
REQUIRED_BY_UXPLAY = ["libav", "playback", "autodetect"]
PLUGINS = USED + REQUIRED_BY_UXPLAY

SYSTEM = ("/usr/lib/", "/System/")


def otool(flag, path):
    return subprocess.check_output(["otool", flag, path], text=True)


def rpaths(path):
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+)", otool("-l", path))


def dependencies(path):
    """(reference as written, real file) for each non-system library `path` loads."""
    folder = os.path.dirname(os.path.realpath(path))
    found = []
    for line in otool("-L", path).splitlines()[1:]:
        reference = line.strip().split(" (")[0]
        if reference.startswith(SYSTEM):
            continue
        if reference.startswith("@rpath/"):
            name = reference[len("@rpath/"):]
            candidates = [r.replace("@loader_path", folder).replace("@executable_path", folder) + "/" + name for r in rpaths(path)]
            candidates.append(os.path.join(folder, name))
        elif reference.startswith("@loader_path/"):
            candidates = [os.path.join(folder, reference[len("@loader_path/"):])]
        else:
            candidates = [reference]
        real = next((os.path.realpath(c) for c in candidates if os.path.exists(c)), None)
        if real is None:
            sys.exit(f"error: can't find {reference}, needed by {path}")
        found.append((reference, real))
    return found


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    uxplay, out = os.path.realpath(sys.argv[1]), sys.argv[2]

    # GStreamer is wherever uxplay's own libgstreamer lives.
    core = next((real for _, real in dependencies(uxplay) if os.path.basename(real).startswith("libgstreamer-1.0")), None)
    if core is None:
        sys.exit(f"error: {uxplay} doesn't link GStreamer")
    prefix = os.path.dirname(os.path.dirname(core))
    plugin_folder = os.path.join(prefix, "lib", "gstreamer-1.0")
    scanner = os.path.join(prefix, "libexec", "gstreamer-1.0", "gst-plugin-scanner")

    shutil.rmtree(out, ignore_errors=True)
    for sub in ("bin", "lib/gstreamer-1.0", "libexec"):
        os.makedirs(os.path.join(out, sub))

    placed = {}   # file in the output folder -> the original it was copied from
    todo = []

    def place(source, destination):
        if destination in placed:
            return
        if not os.path.exists(source):
            sys.exit(f"error: {source} is missing")
        shutil.copy2(source, destination)
        os.chmod(destination, 0o755)
        placed[destination] = os.path.realpath(source)
        todo.append(destination)

    place(uxplay, os.path.join(out, "bin", "uxplay"))
    place(scanner, os.path.join(out, "libexec", "gst-plugin-scanner"))
    for name in PLUGINS:
        place(os.path.join(plugin_folder, f"libgst{name}.dylib"), os.path.join(out, "lib", "gstreamer-1.0", f"libgst{name}.dylib"))

    # Each file finds the libraries through an rpath relative to itself.
    rpath_for = {
        "bin": "@executable_path/../lib",
        "libexec": "@executable_path/../lib",
        "lib": "@loader_path",
        "lib/gstreamer-1.0": "@loader_path/..",
    }
    while todo:
        destination = todo.pop()
        kind = os.path.relpath(os.path.dirname(destination), out)
        command = ["install_name_tool"]
        for reference, real in dependencies(placed[destination]):
            if real == placed[destination]:
                continue  # a library's reference to itself
            name = os.path.basename(reference)
            place(real, os.path.join(out, "lib", name))
            command += ["-change", reference, "@rpath/" + name]
        if kind.startswith("lib"):
            command += ["-id", "@rpath/" + os.path.basename(destination)]
        for old in dict.fromkeys(rpaths(destination)):
            command += ["-delete_rpath", old]
        command += ["-add_rpath", rpath_for[kind], destination]
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Changing a file's load commands invalidates its signature; Apple Silicon won't run it unsigned.
    for destination in placed:
        subprocess.run(["codesign", "--force", "--sign", "-", destination], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    leftovers = [d for d in placed if any(not ref.startswith("@") for ref, _ in
                 [(line.strip().split(" (")[0], None) for line in otool("-L", d).splitlines()[1:]]
                 if not ref.startswith(SYSTEM))]
    if leftovers:
        sys.exit("error: these still load libraries from outside the folder: " + ", ".join(os.path.relpath(d, out) for d in leftovers))

    size = sum(os.path.getsize(d) for d in placed) / 1e6
    print(f"Packaged uxplay with {len(PLUGINS)} plugins and {len(placed) - len(PLUGINS) - 2} libraries ({size:.0f} MB) in {out}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Prints the "What's new" part of a release's notes: the CHANGELOG.md entries that are new or
changed since the previous release's tag, or the newest entry if there was no earlier release.

Usage: release-notes.py [previous tag]
"""
import re
import subprocess
import sys


def entries(markdown):
    """(heading, text) for each `## ` section, newest first."""
    parts = re.split(r"^## ", markdown, flags=re.MULTILINE)[1:]
    return [(part.split("\n", 1)[0].strip(), part.split("\n", 1)[1].strip() if "\n" in part else "") for part in parts]


def main():
    current = entries(open("CHANGELOG.md").read())
    previous = None
    if len(sys.argv) > 1 and sys.argv[1]:
        try:
            previous = dict(entries(subprocess.check_output(["git", "show", f"{sys.argv[1]}:CHANGELOG.md"], text=True, stderr=subprocess.DEVNULL)))
        except subprocess.CalledProcessError:
            previous = {}  # the previous release had no change log
    if previous is None or not previous:
        new = current[:1]
    else:
        new = [(heading, text) for heading, text in current if previous.get(heading) != text]
    for heading, text in new:
        print(f"### {heading}\n\n{text}\n")


if __name__ == "__main__":
    main()

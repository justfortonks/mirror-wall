#!/usr/bin/env python3
"""Inspect every embedded Mach-O before signing; never guess its deployment target.

Read-only by default: bundle-compatibility.py MirrorWall.app
Build step: bundle-compatibility.py MirrorWall.app --write-plist
A universal app must have every embedded component for each app architecture.
Rebuild incompatible dependencies rather than changing their Mach-O version fields.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

MACHO_MAGIC = {
    bytes.fromhex(value) for value in (
        'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
        'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca',
    )
}
ARCHITECTURES = re.compile(r'\b(?:arm64e|arm64|x86_64h|x86_64|i386|ppc64|ppc)\b')


def run_command(command):
    return subprocess.check_output(command, text=True, stderr=subprocess.PIPE)


def version_tuple(value):
    if not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        raise ValueError(f'invalid macOS version: {value!r}')
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def version_text(value):
    return '.'.join(str(part) for part in (value if value[2] else value[:2]))


def minimum_from_load_commands(output, label):
    versions = []
    for block in re.split(r'(?m)^\s*cmd ', output)[1:]:
        command = block.splitlines()[0].strip()
        if command == 'LC_BUILD_VERSION':
            platform = re.search(r'(?m)^\s*platform\s+(\S+)', block)
            if not platform or platform.group(1).lower() not in ('1', 'macos', 'macosx'):
                raise ValueError(f'{label}: unsupported platform in LC_BUILD_VERSION')
            minimum = re.search(r'(?m)^\s*minos\s+(\S+)', block)
        elif command == 'LC_VERSION_MIN_MACOSX':
            minimum = re.search(r'(?m)^\s*version\s+(\S+)', block)
        else:
            continue
        if minimum:
            versions.append(version_tuple(minimum.group(1)))
    if not versions:
        raise ValueError(f'{label}: missing minimum macOS load command')
    return max(versions)


def inspect_bundle(bundle, run=run_command):
    bundle = Path(bundle).resolve()
    contents = bundle / 'Contents'
    with (contents / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    executable = contents / 'MacOS' / info['CFBundleExecutable']
    declared = version_tuple(info.get('LSMinimumSystemVersion', '0.0'))
    components = {}
    seen = set()
    for path in sorted(contents.rglob('*')):
        if not path.is_file() or path.resolve() in seen:
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in MACHO_MAGIC:
            continue
        description = run(['file', '-b', str(path)])
        if 'Mach-O' not in description:
            continue  # Java class files also start with CAFEBABE.
        if bundle not in path.resolve().parents:
            raise ValueError(f'{path}: Mach-O symlink points outside the app bundle')
        seen.add(path.resolve())
        arches = sorted(set(ARCHITECTURES.findall(description)))
        if not arches:
            raise ValueError(f'{path}: unrecognized Mach-O architecture: {description.strip()}')
        components[str(path.relative_to(contents))] = {
            arch: minimum_from_load_commands(
                run(['otool', '-arch', arch, '-l', str(path)]), f'{path} ({arch})'
            ) for arch in arches
        }
    main = str(executable.relative_to(contents))
    if main not in components:
        raise ValueError(f'{executable}: app executable is missing or is not Mach-O')
    app_arches = set(components[main])
    errors = []
    for path, versions in components.items():
        missing = app_arches - versions.keys()
        if missing:
            errors.append(f'{path}: missing app architecture(s) {", ".join(sorted(missing))}; provides {", ".join(versions)}')
    if errors:
        raise ValueError('incompatible embedded components:\n' + '\n'.join(errors))
    floors = {}
    limiting = {}
    for arch in sorted(app_arches):
        # Launch Services uses a per-architecture entry in preference to the global floor.
        declared_arch = version_tuple(info.get('LSMinimumSystemVersionByArchitecture', {}).get(arch, version_text(declared)))
        floor = max(declared_arch, *(versions[arch] for versions in components.values()))
        floors[arch] = version_text(floor)
        limiting[arch] = [path for path, versions in components.items() if versions[arch] == floor]
    return {
        'minimum_macos': version_text(max(version_tuple(value) for value in floors.values())),
        'declared_minimum_macos': version_text(declared),
        'minimum_by_architecture': floors,
        'limiting_components': limiting,
        'component_count': len(components),
    }


def write_minimum_versions(bundle, report):
    path = Path(bundle) / 'Contents/Info.plist'
    with path.open('rb') as stream:
        info = plistlib.load(stream)
    info['LSMinimumSystemVersion'] = report['minimum_macos']
    info['LSMinimumSystemVersionByArchitecture'] = report['minimum_by_architecture']
    with path.open('wb') as stream:
        plistlib.dump(info, stream, sort_keys=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--write-plist', action='store_true', help='update requirements before signing; otherwise inspect only')
    args = parser.parse_args()
    try:
        report = inspect_bundle(args.bundle)
        if args.write_plist:
            write_minimum_versions(args.bundle, report)
        print(json.dumps(report, indent=2))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()

import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('bundle_compatibility', Path(__file__).parents[1] / 'bundle-compatibility.py')
compat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compat)


def modern(version, platform='1'):
    return f'''Load command 10
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform {platform}
    minos {version}
      sdk 27.0
'''


class CompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'MirrorWall.app'
        (self.root / 'Contents/MacOS').mkdir(parents=True)
        self.plist = self.root / 'Contents/Info.plist'
        self.plist.write_bytes(plistlib.dumps({'CFBundleExecutable': 'MirrorWall', 'LSMinimumSystemVersion': '14.0'}))
        self.responses = {}

    def binary(self, relative, versions):
        path = self.root / 'Contents' / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture')
        arches = list(versions)
        desc = f'Mach-O 64-bit executable {arches[0]}' if len(arches) == 1 else 'Mach-O universal binary with 2 architectures: ' + ' '.join(f'[{a}: Mach-O 64-bit {a}]' for a in arches)
        self.responses[('file', '-b', str(path))] = desc
        for arch, version in versions.items():
            self.responses[('otool', '-arch', arch, '-l', str(path))] = modern(version)
        return path

    def inspect(self):
        return compat.inspect_bundle(self.root, run=lambda command: self.responses[tuple(command)])

    def test_reports_transitive_library_floor_without_mutating_plist(self):
        self.binary('MacOS/MirrorWall', {'arm64': '14.0'})
        self.binary('Resources/receiver/bin/uxplay', {'arm64': '26.0'})
        self.binary('Resources/receiver/lib/libglib.dylib', {'arm64': '27.0'})
        before = self.plist.read_bytes()
        result = self.inspect()
        self.assertEqual(result['minimum_macos'], '27.0')
        self.assertIn('Resources/receiver/lib/libglib.dylib', result['limiting_components']['arm64'])
        self.assertEqual(self.plist.read_bytes(), before)

    def test_universal_bundle_has_architecture_specific_floors(self):
        self.binary('MacOS/MirrorWall', {'arm64': '14.0', 'x86_64': '14.0'})
        self.binary('Resources/android/adb', {'arm64': '15.2', 'x86_64': '14.5'})
        self.assertEqual(self.inspect()['minimum_by_architecture'], {'arm64': '15.2', 'x86_64': '14.5'})

    def test_incompatible_universal_dependency_fails_with_specific_path_and_arch(self):
        self.binary('MacOS/MirrorWall', {'arm64': '14.0', 'x86_64': '14.0'})
        self.binary('Resources/receiver/bin/uxplay', {'arm64': '27.0'})
        with self.assertRaisesRegex(ValueError, r'uxplay.*x86_64'):
            self.inspect()

    def test_declared_floor_is_not_lowered(self):
        self.binary('MacOS/MirrorWall', {'arm64': '11.0'})
        self.assertEqual(self.inspect()['minimum_macos'], '14.0')

    def test_legacy_version_load_command_and_numeric_comparison(self):
        self.binary('MacOS/MirrorWall', {'arm64': '14.0'})
        library = self.binary('Frameworks/Old.dylib', {'arm64': '14.9'})
        self.responses[('otool', '-arch', 'arm64', '-l', str(library))] = 'cmd LC_VERSION_MIN_MACOSX\n cmdsize 16\n version 14.10.1\n sdk 27.0\n'
        self.assertEqual(self.inspect()['minimum_macos'], '14.10.1')

    def test_non_macos_platform_is_rejected(self):
        path = self.binary('MacOS/MirrorWall', {'arm64': '14.0'})
        self.responses[('otool', '-arch', 'arm64', '-l', str(path))] = modern('18.0', platform='2')
        with self.assertRaisesRegex(ValueError, 'platform'):
            self.inspect()

    def test_missing_minimum_is_rejected(self):
        path = self.binary('MacOS/MirrorWall', {'arm64': '14.0'})
        self.responses[('otool', '-arch', 'arm64', '-l', str(path))] = 'cmd LC_UUID\n'
        with self.assertRaisesRegex(ValueError, 'minimum macOS'):
            self.inspect()

    def test_extra_dependency_slice_does_not_raise_supported_floor(self):
        self.binary('MacOS/MirrorWall', {'arm64': '14.0'})
        self.binary('Resources/android/adb', {'arm64': '14.0', 'x86_64': '27.0'})
        self.assertEqual(self.inspect()['minimum_macos'], '14.0')

    def test_repeated_inspection_preserves_per_architecture_floors(self):
        self.binary('MacOS/MirrorWall', {'arm64': '15.0', 'x86_64': '14.0'})
        first = self.inspect()
        compat.write_minimum_versions(self.root, first)
        self.assertEqual(self.inspect()['minimum_by_architecture'], first['minimum_by_architecture'])

    def test_update_preserves_other_plist_fields_and_sets_architecture_floors(self):
        self.binary('MacOS/MirrorWall', {'arm64': '14.0'})
        self.binary('Resources/receiver/bin/uxplay', {'arm64': '27.0'})
        compat.write_minimum_versions(self.root, self.inspect())
        values = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(values['CFBundleExecutable'], 'MirrorWall')
        self.assertEqual(values['LSMinimumSystemVersion'], '27.0')
        self.assertEqual(values['LSMinimumSystemVersionByArchitecture'], {'arm64': '27.0'})


if __name__ == '__main__':
    unittest.main()

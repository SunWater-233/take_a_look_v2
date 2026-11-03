"""Portable checks of the updater metadata required in delivered Mac bundles."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
from verify_macos_package import verify_update_metadata


class MacosUpdatePackageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / 'Take A Look 中文.app'
        self.manifest = self.app / 'Contents/Resources/UPDATE-MANIFEST.json'
        self.files = ['Contents/MacOS/take_a_look_v2', 'Contents/Helpers/take_a_look_updater',
                      'Contents/Resources/UPDATE-MANIFEST.json']
        for relative in self.files:
            target = self.app / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b'fixture')
        self.values = dict(schema=1, kind='macos-app', version='1.2.3+4', architecture='arm64', files=self.files)
        self.write_manifest()

    def write_manifest(self):
        self.manifest.write_text(json.dumps(self.values), encoding='utf-8')

    def test_bundle_contains_updater_and_matches_release_metadata(self):
        verify_update_metadata(self.app, 'arm64', '1.2.3+4')

    def test_wrong_kind_architecture_version_or_schema_is_not_publishable(self):
        for field, value in [('kind', 'linux-archive'), ('architecture', 'x64'),
                             ('version', '9.0.0'), ('schema', 2)]:
            with self.subTest(field=field):
                original = self.values[field]
                self.values[field] = value
                self.write_manifest()
                with self.assertRaises(AssertionError):
                    verify_update_metadata(self.app, 'arm64', '1.2.3+4')
                self.values[field] = original

    def test_missing_updater_is_not_publishable(self):
        (self.app / self.files[1]).unlink()
        with self.assertRaises(AssertionError):
            verify_update_metadata(self.app, 'arm64', '1.2.3+4')

    def test_updater_must_also_be_in_the_signed_manifest(self):
        self.values['files'] = [self.files[0], self.files[2]]
        self.write_manifest()
        with self.assertRaises(AssertionError):
            verify_update_metadata(self.app, 'arm64', '1.2.3+4')


if __name__ == '__main__':
    unittest.main()

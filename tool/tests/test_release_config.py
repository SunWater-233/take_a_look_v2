import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
from package_macos import patch_macos_project

SPEC = importlib.util.spec_from_file_location("release_config", Path(__file__).parents[1] / "ci/release_config.py")
config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(config)


class ReleaseConfigurationTest(unittest.TestCase):
    def test_default_builds_both_mac_architectures_and_windows_linux(self):
        result = config.configure({}, "workflow_dispatch", "refs/heads/master", "version: 1.2.3+4\n")
        platforms = json.loads(result["matrix"])["include"]
        self.assertEqual([(row["target"], row["arch"]) for row in platforms],
                         [("windows", "x64"), ("linux", "x64"), ("macos", "arm64"), ("macos", "x64")])
        self.assertEqual(result["version"], "1.2.3+4")

    def test_tag_forces_release_and_uses_its_version(self):
        result = config.configure({"inputs": {"mode": "debug", "version": "9.9.9", "target": "linux"}},
                                  "push", "refs/tags/v1.2.3+4", "version: 0.1.0+1")
        self.assertEqual((result["version"], result["mode"]), ("1.2.3+4", "release"))
        self.assertEqual(len(json.loads(result["matrix"])["include"]), 4)

    def test_manual_target_and_version_override(self):
        result = config.configure({"inputs": {"mode": "debug", "version": "2.3.4", "target": "macos"}},
                                  "workflow_dispatch", "refs/heads/master", "version: 0.1.0+1")
        self.assertEqual(result["version"], "2.3.4")
        self.assertEqual(result["mode"], "debug")
        self.assertEqual(len(json.loads(result["matrix"])["include"]), 2)

    def test_invalid_or_injected_inputs_fail_before_allocating_runners(self):
        for inputs in ({"version": "1.2.3\nmode=debug"}, {"version": "$(touch injected)"},
                       {"version": "256.1.0"}, {"target": "darwin"}, {"mode": "profile"}):
            with self.subTest(inputs=inputs), self.assertRaises(ValueError):
                config.configure({"inputs": inputs}, "workflow_dispatch", "refs/heads/master", "version: 1.0.0")

    def test_linux_does_not_inherit_msi_version_limits(self):
        result = config.configure({"inputs": {"target": "linux", "version": "256.1.0"}},
                                  "workflow_dispatch", "refs/heads/master", "")
        self.assertEqual(result["version"], "256.1.0")


class MacosIsolatedProjectTest(unittest.TestCase):
    def test_same_version_is_valid_and_native_architecture_is_selected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "pubspec.yaml").write_text("name: fixture\nversion: 1.2.3+4\n", encoding="utf-8")
            runner = source / "macos/Runner"
            (runner / "Configs").mkdir(parents=True)
            (runner / "Configs/AppInfo.xcconfig").write_text("PRODUCT_NAME = fixture\n", encoding="utf-8")
            for name in ("Release.entitlements", "DebugProfile.entitlements"):
                with (runner / name).open("wb") as stream:
                    plistlib.dump({"com.apple.security.app-sandbox": True,
                                   "com.apple.security.cs.allow-jit": True}, stream)
            patch_macos_project(source, "arm64", "1.2.3+4")
            self.assertIn("version: 1.2.3+4", (source / "pubspec.yaml").read_text())
            self.assertIn("EXCLUDED_ARCHS = x86_64", (runner / "Configs/AppInfo.xcconfig").read_text())
            with (runner / "DebugProfile.entitlements").open("rb") as stream:
                values = plistlib.load(stream)
            self.assertFalse(values["com.apple.security.app-sandbox"])
            self.assertTrue(values["com.apple.security.cs.allow-jit"])
            patch_macos_project(source, "x64", "2.3.4")
            self.assertIn("version: 2.3.4+0", (source / "pubspec.yaml").read_text())


if __name__ == "__main__":
    unittest.main()

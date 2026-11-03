"""Build routing and cleanup checks; no desktop SDK or external packages needed."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("desktop_build", Path(__file__).parents[1] / "build.py")
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


class BuildRoutingTest(unittest.TestCase):
    def options(self, *args):
        options = build.parser().parse_args(args)
        options.version = options.version or "1.2.3+4"
        return options

    def test_all_builds_windows_once_and_forwards_linux_arguments(self):
        options = self.options("--target", "all", "--mode", "debug", "--distribution", "Ubuntu 中文",
                               "--native", "--keep-build")
        windows, linux = build.build_commands(options, Path("project with spaces"), "nt", "win32")
        self.assertEqual(windows[windows.index("-Package") + 1], "all")
        for command in (windows, linux):
            self.assertEqual(command[command.index("-Mode") + 1], "debug")
            self.assertEqual(command[command.index("-Version") + 1], "1.2.3+4")
        self.assertEqual(linux[linux.index("-Distribution") + 1], "Ubuntu 中文")
        self.assertIn("-Native", linux)
        self.assertIn("-KeepBuild", linux)

    def test_native_linux_routes_without_windows_powershell(self):
        (command,) = build.build_commands(self.options("--target", "linux", "--native", "--check"), Path("repo"), "posix", "linux")
        self.assertEqual(command[0], "bash")
        self.assertIn("--native", command)
        self.assertIn("--check", command)
        self.assertIn("--mode", command)

    def test_unsupported_host_and_reuse_options_fail_before_building(self):
        for arguments, host in [(("--target", "all"), "posix"),
                                (("--target", "linux", "--skip-build"), "nt"),
                                (("--target", "windows", "--skip-build", "--clean"), "nt")]:
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                build.build_commands(self.options(*arguments), Path("repo"), host, "linux" if host == "posix" else "win32")

    def test_macos_uses_native_python_worker_and_forwards_options(self):
        (command,) = build.build_commands(self.options("--target", "macos", "--mode", "debug", "--check", "--keep-build"), Path("repo"), "posix", "darwin")
        self.assertEqual(command[0], sys.executable)
        self.assertTrue(command[1].endswith("package_macos.py"))
        self.assertEqual(command[command.index("--mode") + 1], "debug")
        self.assertIn("--check", command)
        self.assertIn("--keep-build", command)

    def test_macos_target_is_rejected_on_windows_and_linux(self):
        for host, platform_name in (("nt", "win32"), ("posix", "linux")):
            with self.assertRaises(ValueError):
                build.build_commands(self.options("--target", "macos"), Path("repo"), host, platform_name)

    def test_msi_and_exe_version_limits(self):
        for arguments in [("--target", "windows", "--version", "256.0.0"),
                          ("--target", "windows", "--windows-package", "portable", "--version", "1.2.3+65536")]:
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                build.build_commands(self.options(*arguments), Path("repo"), "nt")

    def test_default_version_does_not_change_pubspec(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "pubspec.yaml"
            text = "name: fixture\nversion: 1.2.3+4 # build\n"
            source.write_text(text, encoding="utf-8")
            self.assertEqual(build.read_version(root), "1.2.3+4")
            self.assertEqual(source.read_text(encoding="utf-8"), text)


class BuildCleanupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name)

    def write(self, name, content=b"keep"):
        path = self.project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def clean(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            return build.clean_build(self.project, **kwargs)

    def test_preserves_packages_tools_logs_and_recordings_in_place(self):
        keep = [self.write(name) for name in (
            "build/releases/test.msi", "build/tools/wix.exe", "build/logs/build.log",
            "build/old 中文/recordings/session/samples.talraw", "build/old 中文/recordings/session/index.json",
            "build/other/custom.TALRAW", "build/.desktop-build.lock", "source.txt")]
        stale = [self.write("build/old 中文/source/app.exe", b"stale"), self.write("build/other/cache.log", b"cache")]
        self.assertEqual(self.clean(), (2, 10))
        self.assertTrue(all(path.read_bytes() == b"keep" for path in keep))
        self.assertTrue(all(not path.exists() for path in stale))
        self.assertFalse((self.project / "build/old 中文/source").exists())
        self.assertEqual(self.clean(), (0, 0))

    def test_dry_run_is_read_only(self):
        stale = self.write("build/cache/app.exe", b"1234")
        self.assertEqual(self.clean(dry_run=True), (1, 4))
        self.assertEqual(stale.read_bytes(), b"1234")

    def test_directory_link_is_removed_without_following_its_target(self):
        outside = self.write("outside/important.txt")
        link = self.project / "build/cache-link"
        link.parent.mkdir()
        try:
            link.symlink_to(outside.parent, target_is_directory=True)
        except OSError:
            # Windows junction creation does not require Developer Mode/admin.
            if build.os.name != "nt":
                raise
            result = subprocess.run(["cmd.exe", "/c", "mklink", "/J", str(link), str(outside.parent)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.clean()
        self.assertEqual(outside.read_bytes(), b"keep")
        self.assertFalse(link.exists())

    def test_linked_build_root_is_rejected(self):
        outside = self.write("outside/important.txt")
        link = self.project / "build"
        try:
            link.symlink_to(outside.parent, target_is_directory=True)
        except OSError:
            if build.os.name != "nt":
                raise
            subprocess.run(["cmd.exe", "/c", "mklink", "/J", str(link), str(outside.parent)], check=True, capture_output=True)
        with self.assertRaises(ValueError):
            self.clean()
        self.assertEqual(outside.read_bytes(), b"keep")

    def test_second_build_cannot_clean_an_active_build(self):
        with build.build_lock(self.project):
            with self.assertRaises(ValueError):
                with build.build_lock(self.project):
                    self.fail("acquired the same build lock twice")

    @unittest.skipUnless(build.os.name == "nt", "Windows working-directory locks")
    def test_empty_directory_in_use_does_not_prevent_cleaning_other_files(self):
        directory = self.project / "build/in-use"
        directory.mkdir(parents=True)
        stale = self.write("build/other/cache.log", b"stale")
        process = subprocess.Popen([sys.executable, "-c", "import sys; print('ready', flush=True); sys.stdin.read()"],
                                   cwd=directory, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            self.assertEqual(process.stdout.readline().strip(), b"ready")
            self.clean()
            self.assertFalse(stale.exists())
            self.assertEqual(list(directory.iterdir()), [])
        finally:
            process.terminate()
            process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()


if __name__ == "__main__":
    unittest.main()

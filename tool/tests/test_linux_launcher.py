"""Exercise the shipped launcher with a fake UI and dependency probe."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "linux", "Linux launcher")
class LinuxLauncherTest(unittest.TestCase):
    def test_native_wayland_default_and_explicit_x11_override(self):
        launcher = Path(__file__).resolve().parents[2] / "packaging/linux/take-a-look"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copyfile(launcher, root / "take-a-look")
            (root / "runtime-requirements").write_text(f"{os.uname().machine} 2.0\n")
            for name, source in {
                "ldd": "#!/bin/sh\nexit 0\n",
                "take_a_look_v2": '#!/bin/sh\nprintf "%s\\n" "$GDK_BACKEND"\n',
            }.items():
                path = root / name
                path.write_text(source)
                path.chmod(0o755)
            for session, expected in [
                ({"DISPLAY": ":1", "WAYLAND_DISPLAY": "wayland-1"}, "wayland,x11"),
                ({"WAYLAND_DISPLAY": "wayland-1"}, "wayland,x11"),
                ({"DISPLAY": ":1"}, "x11"),
                ({"DISPLAY": ":1", "WAYLAND_DISPLAY": "wayland-1", "GDK_BACKEND": "x11"}, "x11"),
                ({"DISPLAY": ":1", "GDK_BACKEND": "wayland"}, "wayland"),
            ]:
                with self.subTest(session=session):
                    environment = {key: value for key, value in os.environ.items()
                                   if key not in ("DISPLAY", "WAYLAND_DISPLAY", "GDK_BACKEND")}
                    environment.update(session)
                    environment["PATH"] = str(root) + os.pathsep + environment["PATH"]
                    result = subprocess.run(["bash", str(root / "take-a-look")],
                                            env=environment, check=True, capture_output=True, text=True)
                    self.assertEqual(result.stdout.strip(), expected)


if __name__ == "__main__":
    unittest.main()

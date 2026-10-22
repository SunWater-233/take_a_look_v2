from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

import pytest

from take_a_look_backend.services.parent_lifetime import watch_desktop_process


def test_standalone_backend_does_not_watch_a_desktop(monkeypatch):
    monkeypatch.delenv("TAL_PARENT_PID", raising=False)
    stopped = watch_desktop_process(lambda: pytest.fail("Unexpected cleanup"))
    assert not stopped.is_set()
    stopped.set()


@pytest.mark.parametrize("cleanup", ["normal", "error", "blocked"])
def test_desktop_exit_cleans_up_with_stdin_still_open(tmp_path, cleanup):
    desktop = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    marker = tmp_path / "cleanup.txt"
    environment = dict(os.environ, TAL_PARENT_PID=str(desktop.pid),
                       PYTHONPATH=str(Path(__file__).resolve().parents[1]))
    script = """
from pathlib import Path
import sys
import time
from take_a_look_backend.services.parent_lifetime import watch_desktop_process

def close():
    Path(sys.argv[1]).write_text('closed')
    if sys.argv[2] == 'blocked':
        time.sleep(60)
    if sys.argv[2] == 'error':
        raise RuntimeError('cleanup failed')

watch_desktop_process(close)
print('ready', flush=True)
sys.stdin.read()
"""
    backend = subprocess.Popen([sys.executable, "-u", "-c", script, str(marker), cleanup],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=environment)
    try:
        assert backend.stdout.readline().strip() == b"ready"
        assert backend.poll() is None
        desktop.terminate()
        desktop.wait(timeout=5)
        # Keep our end of stdin open: EOF cannot rescue a missing watchdog.
        assert backend.wait(timeout=10) == 0
        assert marker.read_text() == "closed"
    finally:
        for process in (desktop, backend):
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        for stream in (backend.stdin, backend.stdout, backend.stderr):
            stream.close()

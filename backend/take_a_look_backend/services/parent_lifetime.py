"""Release hardware when the desktop process exits, even if stdin stays open."""
from __future__ import annotations

import logging
import os
import threading
from collections.abc import Callable

import psutil


def watch_desktop_process(close: Callable[[], None]) -> threading.Event:
    stopped = threading.Event()
    raw_pid = os.environ.get("TAL_PARENT_PID")
    if raw_pid is None:
        return stopped  # Standalone CLI clients own the backend through stdin.
    desktop_pid = int(raw_pid)
    if desktop_pid <= 0 or desktop_pid == os.getpid():
        raise ValueError("TAL_PARENT_PID must identify the desktop process")
    try:
        desktop = psutil.Process(desktop_pid)
    except psutil.NoSuchProcess:
        desktop = None

    def monitor() -> None:
        # Process.is_running() also checks creation time, protecting against PID reuse.
        while desktop is not None and desktop.is_running():
            if stopped.wait(0.5):
                return
        if stopped.is_set():
            return
        # A driver call or a full output pipe must not keep an orphan alive forever.
        deadline = threading.Timer(5.0, os._exit, args=(0,))
        deadline.daemon = True
        deadline.start()
        try:
            close()
        except Exception:
            logging.getLogger(__name__).exception("Backend cleanup after desktop exit failed")
        finally:
            os._exit(0)

    threading.Thread(target=monitor, name="tal-desktop-lifetime", daemon=True).start()
    return stopped

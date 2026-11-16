"""Poll one build output, coalescing writes, replacements and temporary deletion."""
from __future__ import annotations

from pathlib import Path
import time


class FirmwareWatcher:
    def __init__(self, selected_path, refresh, *, settle_seconds=1.0, retry_seconds=3.0):
        self._selected_path = selected_path
        self._refresh = refresh
        self._settle_seconds = settle_seconds
        self._retry_seconds = retry_seconds
        self._observed = None
        self._handled = None
        self._changed_at = 0.0
        self._retry_at = 0.0

    def poll(self, now=None):
        now = time.monotonic() if now is None else now
        text = self._selected_path()
        try:
            stat = Path(text).stat() if text else None
            signature = (text, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns) if stat else None
        except OSError:
            signature = (text, None)
        if signature != self._observed:
            self._observed = signature
            self._changed_at = now
            self._retry_at = 0.0
        if (not signature or len(signature) != 4 or signature == self._handled
                or now - self._changed_at < self._settle_seconds or now < self._retry_at):
            return
        if self._refresh(Path(text)):
            self._handled = signature
        else:
            self._retry_at = now + self._retry_seconds

    def run(self, shutdown):
        while not shutdown.wait(0.5):
            self.poll()

"""Real ELF parser and stdio protocol, with test-owned storage and no probe use."""
from pathlib import Path
import sys
from unittest.mock import patch

from take_a_look_backend import stdio
from take_a_look_backend.service import BackendService


root = Path(sys.argv[1])


def service(sink, **_):
    return BackendService(sink, recording_directory=root / 'records',
                          target_directory=root / 'packs',
                          bundled_target_directory=root / 'bundled')


with patch.object(stdio, 'BackendService', service):
    sys.exit(stdio.StdioServer(sys.stdin, sys.stdout.buffer).run())

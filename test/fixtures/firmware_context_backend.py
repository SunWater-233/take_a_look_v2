"""Real stdio/service path with deterministic symbols and no attached hardware."""
from pathlib import Path
import sys
from unittest.mock import patch

from take_a_look_backend import stdio
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.service import BackendService
from take_a_look_backend.services.debug_info import DebugInfoIndex


root = Path(sys.argv[1])


def symbols(path, **_):
    return [SymbolInfo('counter', 0x20000000 + len(path.read_bytes()), 4,
                       'int32_t', '.data', 'main.c')]


def service(sink, **_):
    return BackendService(sink, recording_directory=root / 'records',
                          target_directory=root / 'packs',
                          bundled_target_directory=root / 'bundled',
                          symbol_loader=symbols,
                          debug_info_loader=lambda *a, **k: DebugInfoIndex())


with patch.object(stdio, 'BackendService', service):
    sys.exit(stdio.StdioServer(sys.stdin, sys.stdout.buffer).run())

"""One file and one lazily decoded DWARF graph per symbol-load transaction."""
from __future__ import annotations

from pathlib import Path


class ElfLoadContext:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.handle = None
        self.elf = None
        self._dwarf = None
        self._dwarf_error = None
        self._loaded_dwarf = False

    def __enter__(self):
        from elftools.elf.elffile import ELFFile
        self.handle = self.path.open("rb")
        try:
            self.elf = ELFFile(self.handle)
        except BaseException:
            self.handle.close()
            raise
        return self

    @property
    def dwarf_info(self):
        if not self._loaded_dwarf:
            self._loaded_dwarf = True
            try:
                self._dwarf = self.elf.get_dwarf_info()
            except Exception as error:
                self._dwarf_error = error
        if self._dwarf_error is not None:
            raise self._dwarf_error
        return self._dwarf

    def __exit__(self, *_args):
        if self.handle is not None:
            self.handle.close()

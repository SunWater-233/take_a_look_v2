"""Include PyUSB's dynamically loaded transport on each desktop platform."""

from ctypes.util import find_library

from PyInstaller.compat import is_win
from PyInstaller.depend.bindepend import resolve_library_path
from PyInstaller.utils.hooks import collect_dynamic_libs


hiddenimports = ["glob", "usb.backend.libusb1", "usb.backend.libusb0", "usb.backend.openusb"]
if is_win:
    hiddenimports.append("libusb_package")
    binaries = collect_dynamic_libs("libusb_package", destdir=".")
else:
    library_name = find_library("usb-1.0")
    library_path = resolve_library_path(library_name) if library_name else None
    if not library_path:
        raise RuntimeError("libusb-1.0 is required when packaging the hardware backend")
    binaries = [(library_path, ".")]

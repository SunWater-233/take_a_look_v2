"""Force PyUSB to use the redistributable libusb-package binary on Windows."""

from PyInstaller.utils.hooks import collect_dynamic_libs


hiddenimports = ["glob", "libusb_package"]
binaries = collect_dynamic_libs("libusb_package", destdir=".")

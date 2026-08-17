# Packaged backend runtime

`tool/build_backend.ps1` or `tool/build_backend.sh` writes the platform-specific
PyInstaller bundle into `runtime/take_a_look_backend/`. The generated bundle is
ignored by Git and included in Flutter assets when present.

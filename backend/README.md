# Take A Look Backend

This package is the local hardware service used by the Flutter desktop app. It
reads JSON-RPC 2.0-inspired messages from standard input and writes responses
and unsolicited events as one JSON object per line on standard output.

It is deliberately a local process, not a TCP server. No debug-probe access is
exposed on the network.

Development setup:

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\python -m pip install -e . pytest
.\.venv\Scripts\pytest -q
```

Start it manually with `python -m take_a_look_backend.stdio`. Diagnostic output
is written only to stderr, so stdout remains a valid protocol stream.

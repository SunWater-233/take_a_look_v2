# Take A Look Backend

This package is the local hardware service used by the Flutter desktop app. It
reads JSON-RPC 2.0-inspired messages from standard input and writes responses
and unsolicited events as one JSON object per line on standard output.

It is a local stdio process, not a TCP server. It can connect as a client to
EmberMobile (v2 QUIC with v1 JSON-lines compatibility) and GDB Server. The Flutter connection settings map
to `setConfig.connectionKind` (`local`, `ember`, `emberGdb`, or `gdb`) and
`setConfig.remoteConfig` (`host`, `gatewayPort`, `gdbPort`, `token`, `gdbPath`,
`core`, and `rttDelivery` (`reliable` or `latest`, all strings). Connection settings can be changed while disconnected.
`connectionCapabilities` reports memory polling, memory writes, and RTT support.

`backends/target_backend.py` defines the target-operation protocol, connection
capabilities and RTT binding consumed by the service and sampler. Local pyOCD
and remote adapters share `TypedMemoryBackend` for coalesced reads, numeric
codecs, register access and write/readback verification. The remote adapter does
not inherit pyOCD connection, target-registry or flash-programming behavior;
those remain in the local adapter. Adapter calls retain the service's existing
serialization and ownership rules.

The GDB adapter starts an installed, architecture-appropriate GDB with MI3;
`pygdbmi` parses the machine output. GDB itself must be installed separately.
The current register interface supports ARM/Cortex-M. The private adapter
retains session and RTT IDs, reports byte loss, and never retries an ambiguous
write or reset after a network error. See the root README for ownership and
running-target sampling behavior.

Development setup:

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\python -m pip install -e . pytest
.\.venv\Scripts\pytest -q
```

Start it manually with `python -m take_a_look_backend.stdio`. Diagnostic output
is written only to stderr, so stdout remains a valid protocol stream.

The `targetCatalog` capability exposes `listTargets`, `inspectTargetPack {path}`,
`importTargetPack {previewId}`, `discardTargetPackPreview {previewId}`,
`removeTargetPack {packId}` and `selectTarget {name, packId}`. Inspection stages
and validates a local CMSIS `.pack`; import commits that exact preview. Pack IDs
are SHA-256 hashes. The library keeps its pack metadata, selected source/version
and recent targets in an atomically replaced `index.json` under `TAL_PACKS_DIR`
or the platform's user data directory (see the root README).

Catalog RPCs run on a separate ordered worker. Only selected targets enter the
pyOCD registry, and each local session restores builtin definitions before
loading its selected pack. This permits choosing a user pack even when a builtin
target has the same normalized name. Disconnect and failed opens clear those
definitions and close the pack archive. Mutations emit state patches containing
`targetPackId`, `targetPartNumber`, `targetPackLabel`, `targetPackMissing` and
`targetCatalogRevision`; detached windows request the shared main-window library.

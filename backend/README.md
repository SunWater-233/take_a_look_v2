# Take A Look Backend

This package is the local hardware service used by the Flutter desktop app. It
reads JSON-RPC 2.0-inspired messages from standard input and writes responses
and unsolicited events as one JSON object per line on standard output.

It is a local stdio process, not a TCP server. It can connect as a client to
EmberMobile (v2 QUIC with v1 JSON-lines compatibility) and GDB Server. The Flutter connection settings map
to `setConfig.connectionKind` (`local`, `ember`, `emberGdb`, or `gdb`) and
`setConfig.remoteConfig` (`host`, `gatewayPort`, `gdbPort`, `token`, `gdbPath`,
`core`, `deviceId`, and `rttDelivery` (`reliable` or `latest`, all strings). Connection settings can be changed while disconnected.
`ember {operation: devices|discover|pair|status|cancel|forget}` exposes discovery
and phone-approved pairing. `pair` accepts `host, port, deviceId?, name?` and
returns immediately; poll `status` for the TLS comparison code and completion.
Discovery/forget run on a separate stdio worker, leaving cancellation and other
commands responsive. Results expose phone metadata only. Credentials are stored
under the local TakeALook configuration directory (`ember/paired-devices.dat`),
with Windows DPAPI or Unix 0700/0600 permissions; `TAL_EMBER_CONFIG_DIR` isolates
the store for tests. A nonempty explicit token overrides `deviceId` authentication.
`connectionCapabilities` reports memory polling, memory writes, and RTT support.

`setMonitorVisibility {enabledKeys: string[]}` updates the runtime demand for
memory watches in monitor mode. Hidden monitors keep their last value and
timestamp; re-enabled monitors are due on the next sampling-loop iteration.
This command preserves watch objects, capture plans, buffered frames and stream
lifecycles, and emits no configuration state. Explicit reads and write/readback
still work. The UI unions all visible inspectors and pinned members before
sending demand; this policy is not persisted in project files. RTT streams are
outside this visibility policy.

`backends/target_backend.py` defines the target-operation protocol, connection
capabilities and RTT binding consumed by the service and sampler. Local pyOCD
and remote adapters share `TypedMemoryBackend` for coalesced reads, numeric
codecs, register access and write/readback verification. The remote adapter does
not inherit pyOCD connection, target-registry or flash-programming behavior;
those remain in the local adapter. Adapter calls retain the service's existing
serialization and ownership rules.
Local pyOCD sessions guard error recovery against re-entry: if clearing a
transfer fault also fails, the original transfer error is returned after probe
locks are released. Failed AP/DP SELECT writes also release the lock acquired
before the access, so a sampler fault cannot leave disconnect or other controls
waiting on a lock owned by the sampler thread. Deferred scatter reads consume
all issued callbacks on failure before reporting the original error; failed
chunks never publish partial values. Failed reads include the requested address
and byte count; the sampler logs a traceback for the first error in each
consecutive failure streak. This does not change the configured SWD frequency
or retry writes.
The J-Link, ST-Link and CMSIS-DAP selections match the loaded pyOCD driver type
rather than product-name text, so OEM names such as SAM-ICE remain selectable
as J-Link. Automatic selection and serial-number filtering retain their existing
behavior.
Local sessions check probe presence once per second even when capture is paused
or no variables are watched. J-Link uses its emulator connection status; other
pyOCD probes are matched by their active unique ID. A read/RTT/status failure
forces an immediate check, and explicit transport-disconnect errors retain
their meaning through exception wrapping. A target memory fault or inconclusive
presence query alone does not disconnect. Confirmed loss pauses sampling, stops
RTT, closes the host probe handle without target resume/breakpoint accesses,
preserves recordings and watches, and emits disconnected state plus one
`probe_disconnected` notification. Cleanup errors do not prevent this transition;
reinsertion requires an explicit connection request.
`services/debug_session.py` owns debug information, requested/resolved
breakpoints, step-over handling, registers and stopped locations. It has no
worker, service reference or lock; the service keeps target operations under
its existing shared probe lock and publishes the resulting events. This keeps
sampling, debug control and firmware downloads in the same serialization domain.
The Flutter client consumes the advertised connection capabilities, including
`targetControl`, and forwards them to detached windows.
Both Ember modes support source firmware downloads. `ember` uses phone firmware
staging and flash-job polling; `emberGdb` uses MI download with independent
section readback. Generic `gdb` retains its existing capability restrictions.
The shared source-task lifecycle pauses acquisition, removes breakpoints, waits
for verified programming, then reloads symbols and applies halt/run settings.
Failed/unknown flash jobs never reset/resume the target or report success.

For the builtin `stm32h723xx` target, J-Link sessions select the generic
`Cortex-M7` device to enable pyOCD's native AP0 block-memory interface and then
restore the configured SWD clock. Other probes and pack targets keep their
connection setup. Local downloads compare readable internal flash by erase
sector using bounded payload reads, skipping sectors whose image bytes match.
Changed sectors retain all their image chunks and bypass a redundant smart-flash
comparison. Any write is followed by a fresh byte-for-byte readback of the whole
image; an entirely matching image completes after its comparison without running
a flash algorithm. RAM, external/unreadable flash and pages spanning erase
sectors retain the general loader. Download output reports comparison, erase/write
and verification times and the number of skipped sectors.

High-frequency acquisition compiles typed block decoders and retains up to eight
read plans, including separate capture/monitor sets. Symbol keys and capture
membership are cached; reloading symbols or changing watches invalidates the
relevant plan. Mixed numeric types, pointers, overlapping aliases and raw-byte
values retain their existing representations. Incomplete reads fail explicitly.
Local pyOCD queues aligned single-word scatter reads with its deferred API;
native accelerated memory interfaces and multiword/unaligned blocks keep the
normal block-read path. Remote adapters
negotiate `memory_batch=1` before using kind 13. Exact variable ranges go to the
phone's memory-map-aware merger; absent that capability, existing reads remain.

Selecting a memory capture rate above 1000 Hz enables short-tail yielding in the
deadline waiter. Lower rates, paused capture and inactive/backpressured capture
retain the lower-CPU waiter. This mode costs more CPU and is not a real-time
guarantee. Waiting explicit controls take priority over the next sampler loop;
an in-progress target operation cannot be preempted.

Above what one probe transaction can deliver, the phone gateway advertises
`memory_sampling_repeat` and the client packs repeated reads of the same ranges
into a single `DAP_Transfer` (kind 15). One transaction then returns `repeat`
reads, with one timestamp and one measured duration per tick; each tick's
samples are placed inside that measured window rather than on a nominal grid, so
`effectiveHz` counts samples while `memoryBurst` reports the packing. Repeated
reads stay on 4-byte-aligned ordinary RAM inside a single 64-byte response
packet; MMIO, unknown maps, unaligned ranges and wide capture sets keep one read
per tick. Samples of one tick are back to back at bus speed, so this raises
throughput and time resolution but not the spacing between ticks.

The `memoryWriteBatch` capability adds `writeWatches {writes: [{key, value}]}`
(1..64 distinct keys). All values are validated before writes begin. Only
adjacent actual write bytes in request order are merged; gaps are never written.
The response and `watchValues` event contain only the affected values after
readback. A target failure can leave a partially applied batch and is never
retried automatically. The existing `writeWatch` contract remains available.
Flutter batches concurrent explicit writes within one microtask, splits repeated
keys in order, and preserves each caller's acknowledgement/error and draft.

The recording worker merges already queued adjacent batches, without waiting to
fill a batch. Drain/export/rotation barriers stop merging, and sample events
retain their original acquisition timestamps. Journals and history are committed
before events are published, including under backpressure and recording failure.

Reproduce host measurements (raw-byte fake target, decoding and recording
included, no physical probe/network/UI):

```powershell
.\backend\.venv\Scripts\python.exe tool/benchmarks/backend_throughput.py --source-root . --output build/performance_review/backend.json
```

Use `--layout mixed` for mixed numeric types; `--source-root` can point to a
baseline checkout. Results include acquisition/recording/delivery frame counts,
CPU cost, sample interval P95/P99 and concurrent explicit-write/readback latency.

The GDB adapter starts an installed, architecture-appropriate GDB with MI3;
`pygdbmi` parses the machine output. GDB itself must be installed separately.
The current register interface supports ARM/Cortex-M. The private adapter
retains session and RTT IDs, reports byte loss, and never retries an ambiguous
write or reset after a network error. See the root README for ownership and
running-target sampling behavior.

For remote GDB, `remoteConfig.gdbMode="memory"` selects a direct standard RSP
memory sampler; the default `"debug"` retains GDB/MI debugging. The sampler
requires no installed GDB and shares the production typed decoding, capture,
recording and publication pipeline. It performs fresh requests without a client
value cache, negotiates NoAck, honors PacketSize, and bounds packets, decoded
RLE and request deadlines. Only server-declared RAM permits gap coalescing;
unknown areas use exact ranges. Server caches must be configured separately.
Pause/continue are explicit; no fallback halts/resets the core on a failed read.

Development setup:

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\python -m pip install -e . pytest
.\.venv\Scripts\pytest -q
```

Start it manually with `python -m take_a_look_backend.stdio`. Diagnostic output
is written only to stderr, so stdout remains a valid protocol stream.

Burst memory reads preserve every returned value but do not have measured
subread times. All reads in a phone batch share its submission `elapsed` and
carry `timing={quality:transaction_window,batchSequence,index,repeat,start,end}`.
`index` is zero-based; `start/end` are the enclosing IO window in seconds on the
same elapsed axis, including queue/USB time. These fields survive the raw journal
(`timing` array parallel to `frames`) and CSV export (`timing_*` columns).

The stdio numeric payload uses version 3 only when timing metadata is present.
Its header is the v2 `<BIIIHQ>` header (zero updatedAtMs means absent). After each
existing timestamp/validity/values frame comes a quality byte: 0 means no timing;
1 is followed by `<QHHdd>` for batchSequence, index, repeat, start, end. Unknown
qualities and truncated payloads are rejected. Ordinary batches retain v1/v2.
The Flutter frontend and bundled backend must be updated together for v3.

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

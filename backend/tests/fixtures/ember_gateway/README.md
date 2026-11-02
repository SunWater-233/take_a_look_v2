This fixture uses the current sibling `EmberMobile/native/ember-v2` crate over
real loopback QUIC. It binds only 127.0.0.1. Pairing approval is exposed solely
on local stdin for tests, never as a gateway RPC. No USB probe is opened.

From the Take A Look repository root:

```powershell
cargo build --manifest-path backend/tests/fixtures/ember_gateway/Cargo.toml --target-dir build/ember-fixture --locked
# Windows: normalize only the generated executable when the checkout has a Low label.
./windows/normalise_runtime_integrity.ps1 -Executable ./build/ember-fixture/debug/tal-ember-fixture.exe
backend/.venv/Scripts/python.exe -m pytest backend/tests/test_ember_pairing.py -q
```

`TAL_EMBER_FIXTURE` can point to another build of this fixture. If the sibling
checkout or executable is unavailable, only the Rust integration tests skip;
store, protocol and Flutter tests still run. Integration covers TLS comparison
codes, approval/rejection/cancel, credential persistence, a phone identity restart,
batch memory reads, certificate binding and revocation of control/data connections.

The fixture has its own Cargo lockfile and build directory and does not edit the
EmberMobile checkout. On hosts where ring's MSVC compiler cannot run, use a local
clang-cl via `CC_x86_64_pc_windows_msvc` for the fixture build.

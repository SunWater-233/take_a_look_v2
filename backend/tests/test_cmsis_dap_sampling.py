from collections import deque
from concurrent.futures import ThreadPoolExecutor
from itertools import count
import struct
from time import time_ns
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest
from pyocd.core.memory_map import MemoryMap, RamRegion
from pyocd.coresight.ap import APv1Address, MEM_AP
from pyocd.coresight.dap import DebugPort
from pyocd.probe.cmsis_dap_probe import CMSISDAPProbe
from pyocd.probe.debug_probe import DebugProbe
from pyocd.probe.pydapaccess.dap_access_cmsis_dap import DAPAccessCMSISDAP

from take_a_look_backend.backends.pyocd_compat import guard_dap_error_recovery
from take_a_look_backend.backends.pyocd_memory import PyOcdMemoryBackend
from take_a_look_backend.models import SymbolInfo, WatchedVariable
from take_a_look_backend.protocol import ProtocolError
from take_a_look_backend.service import BackendService
from take_a_look_backend.services import sampling


class DapInterface:
    vendor_name = product_name = "fixture"
    vid = pid = 0

    def __init__(self, is_bulk):
        self.is_bulk = is_bulk
        self.requests = []
        self.responses = deque()
        self.fail_read = False
        self.frame = 0
        self.max_pending = 0
        self.packet_count = 4

    def get_serial_number(self):
        return "fixture"

    def get_packet_count(self):
        return self.packet_count

    def write(self, packet):
        self.requests.append(bytes(packet))
        if packet[0] == 6:  # Deferred DP ABORT after a transfer failure.
            assert packet[4] == 0
            self.responses.append(bytes((6, packet[2], packet[3], 1)))
            return
        assert packet[0] == 5  # DAP_Transfer
        count = packet[2]
        if self.fail_read:
            self.fail_read = False
            self.responses.append(bytes((5, 0, 2)))  # SWD WAIT
            return
        response = bytearray((5, count, 1))
        offset = 3
        for _ in range(count):
            operation = packet[offset]
            offset += 1
            if operation == 0x05:  # AP TAR write
                address = struct.unpack_from("<I", bytes(packet), offset)[0]
                assert address == 0x20000074
                self.frame += 1
            if operation == 0x0F:  # AP DRW read
                response.extend(struct.pack("<I", self.frame))
            else:
                offset += 4  # SELECT, CSW, TAR, or ABORT write.
        self.responses.append(response)
        self.max_pending = max(self.max_pending, len(self.responses))

    def read(self):
        return self.responses.popleft()


def setup_memory(*, is_bulk=True):
    interface = DapInterface(is_bulk)
    link = DAPAccessCMSISDAP(None, interface)
    link._packet_size = 64
    link._init_deferred_buffers()
    link.set_deferred_transfer(True)
    probe = CMSISDAPProbe(link)
    probe._protocol = DebugProbe.Protocol.SWD
    target = SimpleNamespace(
        session=Mock(), memory_map=MemoryMap(RamRegion(start=0x20000000, length=0x5000)),
    )
    target.dp = DebugPort(probe, target)
    ap = MEM_AP(target.dp, APv1Address(0), 0)
    target.selected_core = SimpleNamespace(ap=ap)
    guard_dap_error_recovery(target)
    backend = PyOcdMemoryBackend()
    backend.target = target
    backend.session = SimpleNamespace(probe=probe)
    symbols = tuple(SymbolInfo(name, 0x20000074 + 4 * i, 4, "uint32_t", ".bss")
                    for i, name in enumerate(("first", "second", "third")))
    return backend, symbols, interface


def test_five_distinct_three_word_reads_fit_in_one_packet():
    backend, symbols, interface = setup_memory()
    frames = backend.read_sample_burst(symbols, 5000, lambda: 2.0)
    assert len(interface.requests) == 1
    assert len(frames) == 5
    for index, frame in enumerate(frames):
        assert frame == (2.0, {symbol.key: index + 1 for symbol in symbols})
        assert frame.timing == {
            "quality": "transaction_window", "batchSequence": 1, "index": index,
            "repeat": 5, "start": 2.0, "end": frames[0].timing["end"],
        }
    assert frames[0].timing["end"] >= 2.0
    assert backend.last_read_metrics["byte_count"] == 60


@pytest.mark.parametrize("rate,address", [(1000, 0x20000074), (5000, 0x40000000), (5000, 0x200003FE)])
def test_low_rate_and_unsuitable_memory_use_the_normal_path(rate, address):
    backend, _, interface = setup_memory()
    symbol = SymbolInfo("value", address, 4, "uint32_t", ".bss")
    assert backend.read_sample_burst((symbol,), rate, lambda: 0.0) is None
    assert not interface.requests


def test_failed_batch_releases_probe_lock_and_can_retry():
    backend, symbols, interface = setup_memory()
    interface.fail_read = True
    with pytest.raises(ProtocolError) as caught:
        backend.read_sample_burst(symbols, 5000, lambda: 0.0)
    assert caught.value.code == "memory_read_failed"
    assert "0x20000074" in str(caught.value)
    with ThreadPoolExecutor(max_workers=1) as worker:
        retry = worker.submit(backend.read_sample_burst, symbols, 5000, lambda: 1.0)
        assert len(retry.result(timeout=1)) == 5


@pytest.mark.parametrize("rate,packets,repeat", [(4000, 2, 4), (5000, 2, 5), (10000, 4, 5)])
@pytest.mark.parametrize("is_bulk", [True, False], ids=["bulk", "hid"])
def test_overclock_batches_within_the_sample_budget(rate, packets, repeat, is_bulk):
    backend, symbols, interface = setup_memory(is_bulk=is_bulk)
    ticks = count()
    frames = backend.read_sample_burst(symbols, rate, lambda: next(ticks) / 1000, overclock=True)
    assert len(interface.requests) == packets
    assert interface.max_pending == packets
    assert not interface.responses
    assert len(frames) == packets * repeat
    assert [frame[1] for frame in frames] == [
        {symbol.key: sample for symbol in symbols} for sample in range(1, len(frames) + 1)
    ]
    assert [frame.timing["batchSequence"] for frame in frames[::repeat]] == list(range(1, packets + 1))
    assert all(frame.timing["start"] <= frame.timing["end"] for frame in frames)
    assert backend.last_read_metrics["sampling_mode"] == "pipeline"


def test_overclock_at_low_rate_uses_single_reads():
    backend, symbols, interface = setup_memory()
    assert backend.read_sample_burst(symbols, 50, lambda: 0.0, overclock=True) is None
    assert not interface.requests


def test_sampler_waits_for_the_next_overclock_batch(monkeypatch, tmp_path):
    backend, symbols, interface = setup_memory(is_bulk=False)
    now = 1.0
    with patch.object(BackendService, "_sampling_loop"):
        service = BackendService(lambda *_: None, memory_backend=backend,
                                 recording_directory=tmp_path, monotonic_clock=lambda: now)
    ticks = iter((1.0009, 1.0021, 1.003, 1.0042, None))
    packet_counts = []

    def wait_for_tick(*_args, **_kwargs):
        nonlocal now
        packet_counts.append(len(interface.requests))
        tick = next(ticks)
        if tick is None:
            service._shutdown.set()
        else:
            now = tick

    monkeypatch.setattr(sampling, "time", SimpleNamespace(perf_counter=lambda: now, time_ns=time_ns))
    monkeypatch.setattr(sampling, "wait_until", wait_for_tick)
    try:
        service._connection_status = "connected"
        service._next_debug_poll_at = 2.0
        service._sample_rate_hz = 5000
        service._memory_overclock = True
        service._watches = {symbol.key: WatchedVariable(symbol, "#00ff00") for symbol in symbols}
        service._sampling_loop()
        assert packet_counts == [2, 2, 4, 4, 6]
    finally:
        service.close()


def test_hid_overclock_with_one_slot_still_batches_reads():
    backend, symbols, interface = setup_memory(is_bulk=False)
    interface.packet_count = 1
    assert backend.memory_pipeline_depth == 1
    assert backend.read_sample_burst(symbols, 5000, lambda: 0.0) is None
    assert not interface.requests
    assert len(backend.read_sample_burst(symbols, 5000, lambda: 0.0, overclock=True)) == 5
    assert len(interface.requests) == 1
    assert backend.last_read_metrics["packets_in_flight"] == 1


def test_other_probe_has_no_overclock_capability():
    backend, symbols, interface = setup_memory()
    backend.session.probe = Mock(spec=DebugProbe)
    assert backend.memory_pipeline_depth == 0
    assert backend.read_sample_burst(symbols, 5000, lambda: 0.0, overclock=True) is None
    assert not interface.requests


def test_pipeline_failure_drains_responses_and_releases_probe_lock():
    backend, symbols, interface = setup_memory()
    interface.fail_read = True
    with pytest.raises(ProtocolError) as caught:
        backend.read_sample_burst(symbols, 5000, lambda: 0.0, overclock=True)
    assert caught.value.code == "memory_read_failed"
    assert not interface.responses
    with ThreadPoolExecutor(max_workers=1) as worker:
        retry = worker.submit(backend.read_sample_burst, symbols, 5000, lambda: 1.0,
                              overclock=True, controls_idle=lambda: False)
        assert len(retry.result(timeout=1)) == 5
    assert len(interface.requests) == 4  # Two reads, one ABORT, one retry before yielding.

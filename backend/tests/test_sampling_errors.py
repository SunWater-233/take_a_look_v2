import logging
import traceback
from types import SimpleNamespace
from unittest.mock import Mock

from test_service import _FakeMemory, _FakeRtt
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import EventName, ProtocolError
from take_a_look_backend.service import BackendService
from take_a_look_backend.services import sampling


def test_sampling_logs_traceback_once_per_failure_streak_and_keeps_retrying(tmp_path, monkeypatch, caplog):
    events = []
    service = BackendService(lambda name, payload: events.append((name, payload)),
                             memory_backend=_FakeMemory(), recording_directory=tmp_path,
                             normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt())
    service._shutdown.set()
    service._wake.set()
    service._sampler.join(2)
    item = SymbolInfo("value", 0x24000000, 4, "uint32_t", ".data")
    fault = ProtocolError("memory_read_failed", "读取内存失败（地址 0x24000000，4 字节）")
    clock, waits = [0.0], []
    monkeypatch.setattr(sampling, "time", SimpleNamespace(perf_counter=lambda: clock[0]))
    def wait_until(wake, deadline, **kwargs):
        waits.append(deadline)
        clock[0] += 1
        if len(waits) == 4:
            service._shutdown.set()
    monkeypatch.setattr(sampling, "wait_until", wait_until)
    service._connection_status = "connected"
    service._debug.execution_state = "running"
    service._next_debug_poll_at = service._last_perf_at = 100
    service._capture_symbols_locked = lambda: (item,)
    service._poll_monitors_locked = lambda now: now + 2
    service._read_memory_locked = Mock(side_effect=[fault, fault, {}, fault])
    service._shutdown.clear()
    try:
        with caplog.at_level(logging.ERROR, logger=sampling.__name__):
            service._sampling_loop()
        assert service._read_memory_locked.call_count == 4
        logs = [r for r in caplog.records if r.name == sampling.__name__]
        assert len(logs) == 2
        assert all(r.exc_info and "0x24000000" in r.getMessage() for r in logs)
        assert "ProtocolError" in "".join(traceback.format_exception(*logs[0].exc_info))
        messages = [p["message"] for name, p in events if name is EventName.LOG]
        assert messages == [f"采样失败：{fault.message}"] * 3
        assert all(deadline >= index + 0.25 for index, deadline in enumerate(waits[:2]))
        assert service._recording.sample_count == 0
    finally:
        service.close()

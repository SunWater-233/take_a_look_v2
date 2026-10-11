from __future__ import annotations

import io
import json
import threading
from pathlib import Path

from take_a_look_backend.protocol import EventName, RpcMethod
from take_a_look_backend.services.ordered_worker import OrderedWorker
from take_a_look_backend.services.sampling_clock import advance_deadline, wait_until
from take_a_look_backend.stdio import StdioServer


def test_worker_backpressure_retains_order_and_does_not_drop_accepted_jobs():
    entered, release = threading.Event(), threading.Event()
    seen = []
    worker = OrderedWorker("test-worker", max_weight=8, max_jobs=2)
    def slow():
        entered.set()
        release.wait(2)
        seen.append(1)
    try:
        first = worker.submit(slow, weight=4)
        assert entered.wait(1)
        second = worker.submit(lambda: seen.append(2), weight=4)
        assert worker.submit(lambda: seen.append(99), weight=1, block=False) is None
        release.set()
        first.result(1)
        second.result(1)
        worker.drain()
        assert seen == [1, 2]
    finally:
        release.set()
        worker.close()


def test_deadlines_skip_missed_reads_without_drift_or_a_one_ms_floor(monkeypatch):
    assert abs(advance_deadline(1.0, 1.0032, 0.001) - 1.004) < 1e-12
    clock = [1.0]
    sleeps = []
    def sleep(delay):
        sleeps.append(delay)
        clock[0] += delay
    monkeypatch.setattr("take_a_look_backend.services.sampling_clock.time.perf_counter", lambda: clock[0])
    monkeypatch.setattr("take_a_look_backend.services.sampling_clock.time.sleep", sleep)
    wait_until(threading.Event(), 1.0001)
    assert len(sleeps) == 1 and 0 < sleeps[0] < 0.001


def test_csv_export_does_not_block_following_control_requests():
    entered, release = threading.Event(), threading.Event()
    output = io.BytesIO()
    server = StdioServer(io.StringIO(), output)
    original = server._service
    original.close()
    class FakeService:
        def prepare_csv_export(self, params):
            return params
        def finish_csv_export(self, params):
            entered.set()
            assert release.wait(2)
            return {"path": params["path"], "sampleCount": 3}
        def handle(self, method, params):
            assert method is RpcMethod.GET_STATE
            return {"state": {"connectionStatus": "connected"}}
        def close(self):
            pass
    server._service = FakeService()
    try:
        server._handle_line(json.dumps({"v": 2, "id": 1, "method": "exportCsv",
                                      "params": {"path": "fixture.csv"}}))
        assert entered.wait(1)
        server._handle_line(json.dumps({"v": 2, "id": 2, "method": "getState", "params": {}}))
        server._output_worker.drain()
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        assert [r["id"] for r in responses] == [2]
    finally:
        release.set()
        server.close()
    responses = [json.loads(line) for line in output.getvalue().splitlines()]
    assert [r["id"] for r in responses] == [2, 1]

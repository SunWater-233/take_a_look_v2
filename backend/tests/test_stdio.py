from __future__ import annotations

import json
import io
import os
import struct
import subprocess
import sys
import unittest
from pathlib import Path

from take_a_look_backend.stdio import StdioServer
from take_a_look_backend.protocol import EventName


class StdioIntegrationTests(unittest.TestCase):
    def test_rejected_requests_keep_their_ids_and_later_requests_work(self) -> None:
        output = io.BytesIO()
        server = StdioServer(io.StringIO(), output)
        try:
            server._handle_line('{"v":3,"id":41,"method":"futureMethod"}')
            server._handle_line('{"v":3,"id":42,"method":"getState","params":[]}')
            server._handle_line('{"v":3,"id":43,"method":"getState"}')
            server._output_worker.drain()
            replies = {item["id"]: item for line in output.getvalue().splitlines()
                       if "id" in (item := json.loads(line))}
            self.assertEqual(replies[41]["error"]["code"], "unknown_method")
            self.assertEqual(replies[42]["error"]["code"], "invalid_request")
            self.assertIn("state", replies[43]["result"])
        finally:
            server.close()

    def test_batch_rpc_reaches_typed_writes_and_returns_readback_deltas(self) -> None:
        import tempfile
        from take_a_look_backend.backends.typed_memory import TypedMemoryBackend
        from take_a_look_backend.models import SymbolInfo
        from take_a_look_backend.protocol import RpcMethod
        from take_a_look_backend.service import BackendService

        class Target:
            def __init__(self):
                self.data = bytearray(8)
                self.operations = []
            def write_memory_block8(self, address, values):
                self.operations.append(("write", address, len(values)))
                self.data[address:address + len(values)] = bytes(values)
            def read_memory_block8(self, address, size):
                self.operations.append(("read", address, size))
                return self.data[address:address + size]
        class Memory(TypedMemoryBackend):
            def disconnect(self):
                self.target = None
        with tempfile.TemporaryDirectory() as directory:
            output = io.BytesIO()
            server = StdioServer(io.StringIO(), output)
            server._service.close()
            memory = Memory()
            target = memory.target = Target()
            server._service = service = BackendService(server._send_event,
                memory_backend=memory, recording_directory=Path(directory))
            service._shutdown.set()
            service._wake.set()
            service._sampler.join(2)
            items = [SymbolInfo(f"v{i}", i * 4, 4, "uint32_t", ".data") for i in range(2)]
            service._symbols = {item.key: item for item in items}
            service.handle(RpcMethod.SET_WATCHES, {"watches": [
                {"key": item.key, "readMode": "manual"} for item in items]})
            service._connection_status = "connected"
            try:
                server._handle_line(json.dumps({"v": 3, "id": 17, "method": "writeWatches",
                    "params": {"writes": [{"key": item.key, "value": str(i + 1)}
                                           for i, item in enumerate(items)]}}))
                server._output_worker.drain()
                messages = [json.loads(line) for line in output.getvalue().splitlines()]
                result = next(message["result"] for message in messages if message.get("id") == 17)
                self.assertEqual([value["value"] for value in result["values"]], [1, 2])
                self.assertNotIn("state", result)
                self.assertEqual(target.operations, [("write", 0, 8), ("read", 0, 8)])
                self.assertEqual(service._recording.sample_count, 0)
            finally:
                server.close()

    def test_stderr_logging_keeps_levels_and_tracebacks_out_of_protocol(self) -> None:
        backend_root = Path(__file__).resolve().parents[1]
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(backend_root)
        script = """
import logging
from take_a_look_backend import stdio

original_run = stdio.StdioServer.run
def run_with_logs(server):
    logger = logging.getLogger("pyocd.coresight.rom_table")
    logger.setLevel(logging.DEBUG)
    logger.warning("Invalid coresight component, cidr=0x0")
    logger.info("No memory transfer errors")
    logger.error("Error attempting to probe CoreSight component: FAULT ACK")
    logger.debug("Scanning ROM table")
    logger.critical("Probe unavailable")
    try:
        raise RuntimeError("SWD/JTAG communication failure (FAULT ACK)")
    except RuntimeError:
        logger.exception("Probe read failed")
    return original_run(server)

stdio.StdioServer.run = run_with_logs
stdio.main()
"""
        requests = "\n".join(
            json.dumps({"v": 3, "id": index, "method": method, "params": {}})
            for index, method in enumerate(("handshake", "shutdown"), start=1)
        ) + "\n"
        completed = subprocess.run(
            [sys.executable, "-c", script],
            cwd=backend_root,
            env=environment,
            input=requests,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        lines = completed.stderr.splitlines()
        self.assertEqual(
            lines[:5],
            [
                "[WARNING] Invalid coresight component, cidr=0x0",
                "[INFO] No memory transfer errors",
                "[ERROR] Error attempting to probe CoreSight component: FAULT ACK",
                "[DEBUG] Scanning ROM table",
                "[CRITICAL] Probe unavailable",
            ],
        )
        self.assertGreater(len(lines), 6)
        self.assertTrue(all(line.startswith("[ERROR] ") for line in lines[5:]))
        self.assertIn("Traceback (most recent call last):", completed.stderr)
        self.assertIn("RuntimeError: SWD/JTAG communication failure", completed.stderr)
        messages = [json.loads(line) for line in completed.stdout.splitlines()]
        responses = {message.get("id"): message for message in messages if "id" in message}
        self.assertEqual(responses[1]["result"]["protocolVersion"], 3)
        self.assertEqual(responses[2]["result"]["state"]["connectionStatus"], "disconnected")

    def test_process_handshake_and_shutdown(self) -> None:
        backend_root = Path(__file__).resolve().parents[1]
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(backend_root)
        requests = "\n".join(
            [
                json.dumps({"v": 3, "id": 1, "method": "handshake", "params": {}}),
                json.dumps({"v": 3, "id": 2, "method": "shutdown", "params": {}}),
                "",
            ]
        )

        completed = subprocess.run(
            [sys.executable, "-m", "take_a_look_backend.stdio"],
            cwd=backend_root,
            env=environment,
            input=requests,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(completed.stdout.isascii())
        messages = [json.loads(line) for line in completed.stdout.splitlines()]
        responses = {message.get("id"): message for message in messages if "id" in message}
        self.assertEqual(responses[1]["result"]["protocolVersion"], 3)
        self.assertEqual(responses[2]["result"]["state"]["connectionStatus"], "disconnected")

    def test_sample_events_are_binary_framed_after_a_json_schema(self) -> None:
        output = io.BytesIO()
        server = StdioServer(io.StringIO(), output)
        try:
            server._send_event(EventName.STATE, {"watches": [{"key": "speed"}]})
            server._send_event(
                EventName.SAMPLES,
                {"frames": [{"elapsed": 0.25, "values": {"speed": 12.5}}]},
            )
        finally:
            server.close()

        raw = output.getvalue()
        marker_offset = raw.index(b"\x00")
        json_messages = [json.loads(line) for line in raw[:marker_offset].splitlines()]
        self.assertEqual(json_messages[0]["event"], "sampleSchema")
        self.assertEqual(json_messages[0]["params"], {"id": 1, "keys": ["speed"]})
        self.assertEqual(json_messages[1]["event"], "state")
        payload_length = struct.unpack_from("<I", raw, marker_offset + 1)[0]
        payload = raw[marker_offset + 5 :]
        self.assertEqual(payload_length, len(payload))
        self.assertEqual(struct.unpack_from("<BIIIH", payload), (1, 1, 1, 1, 1))

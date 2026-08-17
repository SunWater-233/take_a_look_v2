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
    def test_process_handshake_and_shutdown(self) -> None:
        backend_root = Path(__file__).resolve().parents[1]
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(backend_root)
        requests = "\n".join(
            [
                json.dumps({"v": 2, "id": 1, "method": "handshake", "params": {}}),
                json.dumps({"v": 2, "id": 2, "method": "shutdown", "params": {}}),
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
        self.assertEqual(responses[1]["result"]["protocolVersion"], 2)
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
            server._service.close()

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

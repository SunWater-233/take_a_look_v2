from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


class StdioIntegrationTests(unittest.TestCase):
    def test_process_handshake_and_shutdown(self) -> None:
        backend_root = Path(__file__).resolve().parents[1]
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(backend_root)
        requests = "\n".join(
            [
                json.dumps({"v": 1, "id": 1, "method": "handshake", "params": {}}),
                json.dumps({"v": 1, "id": 2, "method": "shutdown", "params": {}}),
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
        messages = [json.loads(line) for line in completed.stdout.splitlines()]
        responses = {message.get("id"): message for message in messages if "id" in message}
        self.assertEqual(responses[1]["result"]["protocolVersion"], 1)
        self.assertEqual(responses[2]["result"]["state"]["connectionStatus"], "disconnected")

from __future__ import annotations

import sys
import threading
from collections.abc import Mapping
from typing import TextIO

from take_a_look_backend.protocol import ProtocolError, encode, error_response, event, parse_request, response
from take_a_look_backend.service import BackendService


class StdioServer:
    def __init__(self, input_stream: TextIO, output_stream: TextIO) -> None:
        self._input = input_stream
        self._output = output_stream
        self._write_lock = threading.Lock()
        self._service = BackendService(self._send_event)

    def run(self) -> int:
        try:
            for raw_line in self._input:
                line = raw_line.strip()
                if not line:
                    continue
                self._handle_line(line)
        finally:
            self._service.close()
        return 0

    def _handle_line(self, line: str) -> None:
        request_id: object | None = None
        try:
            request_id, method, params = parse_request(line)
            result = self._service.handle(method, params)
            self._write(response(request_id, result))
        except ProtocolError as error:
            self._write(error_response(request_id, error))
        except Exception as error:  # Never corrupt the protocol stream with a traceback.
            self._write(error_response(request_id, error))

    def _send_event(self, name: str, params: object) -> None:
        self._write(event(name, params))

    def _write(self, message: Mapping[str, object]) -> None:
        payload = encode(message)
        with self._write_lock:
            self._output.write(payload + "\n")
            self._output.flush()


def main() -> None:
    raise SystemExit(StdioServer(sys.stdin, sys.stdout).run())


if __name__ == "__main__":
    main()

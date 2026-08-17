from __future__ import annotations

import sys
import threading
from collections.abc import Mapping, Sequence
from typing import BinaryIO, TextIO

from take_a_look_backend.protocol import (
    ProtocolError,
    encode,
    encode_sample_batch,
    error_response,
    event,
    frame_sample_payload,
    parse_request,
    response,
)
from take_a_look_backend.service import BackendService


class StdioServer:
    def __init__(self, input_stream: TextIO, output_stream: BinaryIO) -> None:
        self._input = input_stream
        self._output = output_stream
        self._write_lock = threading.Lock()
        self._sample_schema_id = 0
        self._sample_keys: list[str] = []
        self._sample_sequence = 0
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
        if name == "samples" and isinstance(params, Mapping):
            self._write_samples(params)
            return
        if name == "state" and isinstance(params, Mapping):
            self._update_schema_from_state(params)
        self._write(event(name, params))

    def _write(self, message: Mapping[str, object]) -> None:
        with self._write_lock:
            self._write_json_unlocked(message)
            self._output.flush()

    def _write_samples(self, params: Mapping[str, object]) -> None:
        raw_frames = params.get("frames")
        if not isinstance(raw_frames, Sequence):
            return
        frames: list[tuple[float, Mapping[str, object]]] = []
        discovered_keys: list[str] = []
        for raw_frame in raw_frames:
            if not isinstance(raw_frame, Mapping):
                continue
            elapsed = raw_frame.get("elapsed")
            values = raw_frame.get("values")
            if not isinstance(elapsed, (int, float)) or not isinstance(values, Mapping):
                continue
            normalized_values = {str(key): value for key, value in values.items()}
            frames.append((float(elapsed), normalized_values))
            for key in normalized_values:
                if key not in self._sample_keys and key not in discovered_keys:
                    discovered_keys.append(key)
        if not frames:
            return

        with self._write_lock:
            if discovered_keys:
                self._set_sample_schema_unlocked([*self._sample_keys, *discovered_keys])
            self._sample_sequence = (self._sample_sequence + 1) & 0xFFFFFFFF
            payload = encode_sample_batch(
                self._sample_schema_id,
                self._sample_sequence,
                self._sample_keys,
                frames,
            )
            self._output.write(frame_sample_payload(payload))
            self._output.flush()

    def _update_schema_from_state(self, state: Mapping[str, object]) -> None:
        raw_watches = state.get("watches")
        if not isinstance(raw_watches, Sequence):
            return
        keys = [
            str(watch["key"])
            for watch in raw_watches
            if isinstance(watch, Mapping) and isinstance(watch.get("key"), str)
        ]
        with self._write_lock:
            if keys != self._sample_keys:
                self._set_sample_schema_unlocked(keys)
                self._output.flush()

    def _set_sample_schema_unlocked(self, keys: list[str]) -> None:
        self._sample_schema_id = (self._sample_schema_id + 1) & 0xFFFFFFFF
        self._sample_keys = keys
        self._write_json_unlocked(
            event(
                "sampleSchema",
                {"id": self._sample_schema_id, "keys": self._sample_keys},
            )
        )

    def _write_json_unlocked(self, message: Mapping[str, object]) -> None:
        self._output.write(encode(message).encode("ascii") + b"\n")


def main() -> None:
    _configure_standard_stream_encoding()
    raise SystemExit(StdioServer(sys.stdin, sys.stdout.buffer).run())


def _configure_standard_stream_encoding() -> None:
    # PyInstaller's Windows bootloader does not consistently honor PYTHONUTF8
    # for redirected standard streams. Requests from Dart are always UTF-8.
    for stream in (sys.stdin, sys.stdout):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8", errors="strict")
    reconfigure_stderr = getattr(sys.stderr, "reconfigure", None)
    if callable(reconfigure_stderr):
        reconfigure_stderr(encoding="utf-8", errors="backslashreplace")


if __name__ == "__main__":
    main()

from __future__ import annotations

import logging
import sys
import threading
from collections.abc import Mapping, Sequence
from typing import BinaryIO, TextIO

from take_a_look_backend.protocol import (
    EventName,
    RpcMethod,
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
from take_a_look_backend.services.ordered_worker import OrderedWorker
from take_a_look_backend.services.source_project import default_settings_file


class StdioServer:
    def __init__(self, input_stream: TextIO, output_stream: BinaryIO) -> None:
        self._input = input_stream
        self._output = output_stream
        self._write_lock = threading.Lock()
        self._output_worker = OrderedWorker('tal-pipe-output')
        self._export_worker = OrderedWorker('tal-csv-export', max_jobs=8)
        self._output_error: Exception | None = None
        self._closed = False
        self._sample_schema_id = 0
        self._sample_keys: list[str] = []
        self._sample_sequence = 0
        self._service = BackendService(self._send_event, source_settings_file=default_settings_file())

    def run(self) -> int:
        try:
            for raw_line in self._input:
                line = raw_line.strip()
                if not line:
                    continue
                self._handle_line(line)
        finally:
            self.close()
        return 0

    def _handle_line(self, line: str) -> None:
        request_id: object | None = None
        try:
            request_id, method, params = parse_request(line)
            if method is RpcMethod.EXPORT_CSV:
                prepared = self._service.prepare_csv_export(params)
                task = self._export_worker.submit(
                    lambda: self._complete_export(request_id, prepared), block=False)
                if task is None:
                    raise ProtocolError("busy", "CSV 导出队列已满，请等待当前导出完成。")
                return
            result = self._service.handle(method, params)
            self._write(response(request_id, result))
        except ProtocolError as error:
            self._write(error_response(request_id, error))
        except Exception as error:  # Never corrupt the protocol stream with a traceback.
            self._write(error_response(request_id, error))

    def _complete_export(self, request_id, prepared) -> None:
        try:
            self._write(response(request_id, self._service.finish_csv_export(prepared)))
        except Exception as error:
            self._write(error_response(request_id, error))

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self._export_worker.close()
            self._service.close()
        finally:
            self._output_worker.close()

    def _enqueue_output(self, data: bytes) -> None:
        if self._output_error is not None:
            raise self._output_error

        def write():
            try:
                self._output.write(data)
                self._output.flush()
            except Exception as error:
                self._output_error = error
                raise
        self._output_worker.submit(write, weight=len(data))

    def _send_event(self, name: EventName, params: object) -> None:
        if name is EventName.SAMPLES and isinstance(params, Mapping):
            self._write_samples(params)
            return
        if name is EventName.STATE and isinstance(params, Mapping):
            self._update_schema_from_state(params)
        self._write(event(name, params))

    def _write(self, message: Mapping[str, object]) -> None:
        with self._write_lock:
            self._write_json_unlocked(message)

    def _write_samples(self, params: Mapping[str, object]) -> None:
        raw_frames = params.get("frames")
        if not isinstance(raw_frames, Sequence):
            return
        frames: list[tuple[float, Mapping[str, object]]] = []
        frame_keys: set[str] = set()
        for raw_frame in raw_frames:
            if not isinstance(raw_frame, Mapping):
                continue
            elapsed = raw_frame.get("elapsed")
            values = raw_frame.get("values")
            if not isinstance(elapsed, (int, float)) or not isinstance(values, Mapping):
                continue
            normalized_values = values if all(isinstance(key, str) for key in values) else {
                str(key): value for key, value in values.items()}
            frames.append((float(elapsed), normalized_values))
            frame_keys.update(normalized_values)
        if not frames:
            return

        with self._write_lock:
            missing = frame_keys.difference(self._sample_keys)
            if missing:
                # Preserve discovery order even when another state changed the schema.
                keys = list(self._sample_keys)
                seen = set(keys)
                for _, values in frames:
                    for key in values:
                        if key not in seen:
                            keys.append(key)
                            seen.add(key)
                self._set_sample_schema_unlocked(keys)
            self._sample_sequence = (self._sample_sequence + 1) & 0xFFFFFFFF
            payload = encode_sample_batch(
                self._sample_schema_id,
                self._sample_sequence,
                self._sample_keys,
                frames,
            )
            self._enqueue_output(frame_sample_payload(payload))

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

    def _set_sample_schema_unlocked(self, keys: list[str]) -> None:
        self._sample_schema_id = (self._sample_schema_id + 1) & 0xFFFFFFFF
        self._sample_keys = keys
        self._write_json_unlocked(
            event(
                EventName.SAMPLE_SCHEMA,
                {"id": self._sample_schema_id, "keys": self._sample_keys},
            )
        )

    def _write_json_unlocked(self, message: Mapping[str, object]) -> None:
        self._enqueue_output(encode(message).encode("ascii") + b"\n")


def main() -> None:
    _configure_standard_stream_encoding()
    _configure_stderr_logging()
    if sys.argv[1:] == ["--self-test"]:
        from take_a_look_backend.self_check import run

        raise SystemExit(run())
    raise SystemExit(StdioServer(sys.stdin, sys.stdout.buffer).run())


class _StderrLogFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        # Label every line, including tracebacks, so stderr line splitting does
        # not lose the severity of a multiline logging record.
        message = super().format(record)
        return "\n".join(f"[{record.levelname}] {line}" for line in message.split("\n"))


def _configure_stderr_logging() -> None:
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(_StderrLogFormatter())
    # Preserve Python's default verbosity while making the record level explicit.
    logging.basicConfig(level=logging.WARNING, handlers=[handler])


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

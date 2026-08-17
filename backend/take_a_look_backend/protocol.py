from __future__ import annotations

import json
import struct
from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from typing import Any


PROTOCOL_VERSION = 2
SAMPLE_PAYLOAD_VERSION = 1
SAMPLE_FRAME_MARKER = 0


class RpcMethod(StrEnum):
    HANDSHAKE = "handshake"
    GET_STATE = "getState"
    CONNECT = "connect"
    TOGGLE_CONNECTION = "toggleConnection"
    DISCONNECT = "disconnect"
    LOAD_SYMBOLS = "loadSymbols"
    SET_CONFIG = "setConfig"
    SET_WATCHES = "setWatches"
    WRITE_WATCH = "writeWatch"
    SET_SAMPLING_PAUSED = "setSamplingPaused"
    SET_RTT = "setRtt"
    CLEAR_SAMPLES = "clearSamples"
    RESET_TARGET = "resetTarget"
    EXPORT_CSV = "exportCsv"
    SHUTDOWN = "shutdown"


class EventName(StrEnum):
    STATE = "state"
    SAMPLES = "samples"
    SAMPLES_CLEARED = "samplesCleared"
    SAMPLE_SCHEMA = "sampleSchema"
    LOG = "log"
    ERROR = "error"
    PERF = "perf"


@dataclass(frozen=True)
class ProtocolError(Exception):
    code: str
    message: str
    details: object | None = None


def parse_request(line: str) -> tuple[object, RpcMethod, dict[str, object]]:
    try:
        raw = json.loads(line)
    except json.JSONDecodeError as error:
        raise ProtocolError("invalid_json", "Request is not valid JSON.", str(error)) from error
    if not isinstance(raw, Mapping):
        raise ProtocolError("invalid_request", "Request must be a JSON object.")
    if raw.get("v") != PROTOCOL_VERSION:
        raise ProtocolError(
            "unsupported_version",
            f"Protocol version must be {PROTOCOL_VERSION}.",
            raw.get("v"),
        )
    request_id = raw.get("id")
    if request_id is None:
        raise ProtocolError("invalid_request", "Request id is required.")
    raw_method = raw.get("method")
    if not isinstance(raw_method, str) or not raw_method:
        raise ProtocolError("invalid_request", "Method must be a non-empty string.")
    try:
        method = RpcMethod(raw_method)
    except ValueError as error:
        raise ProtocolError("unknown_method", f"Unknown backend method: {raw_method}") from error
    params = raw.get("params", {})
    if not isinstance(params, Mapping):
        raise ProtocolError("invalid_request", "Params must be an object.")
    return request_id, method, dict(params)


def response(request_id: object, result: object) -> dict[str, object]:
    return {"v": PROTOCOL_VERSION, "id": request_id, "result": result}


def error_response(request_id: object | None, error: ProtocolError | Exception) -> dict[str, object]:
    if isinstance(error, ProtocolError):
        payload: dict[str, object] = {"code": error.code, "message": error.message}
        if error.details is not None:
            payload["details"] = error.details
    else:
        payload = {"code": "internal_error", "message": str(error) or type(error).__name__}
    return {"v": PROTOCOL_VERSION, "id": request_id, "error": payload}


def event(name: EventName, params: object) -> dict[str, object]:
    return {"v": PROTOCOL_VERSION, "event": name.value, "params": params}


def encode(message: Mapping[str, Any]) -> str:
    # Keep the wire format ASCII-only. Frozen Python applications on Windows
    # can inherit a legacy console code page even when stdout is a pipe; JSON
    # escapes preserve Unicode without making Flutter guess that encoding.
    return json.dumps(message, ensure_ascii=True, separators=(",", ":"), allow_nan=False)


def encode_sample_batch(
    schema_id: int,
    sequence: int,
    keys: list[str],
    frames: list[tuple[float, Mapping[str, object]]],
) -> bytes:
    """Encode high-rate samples without repeating symbol names per value."""
    if len(keys) > 0xFFFF:
        raise ValueError("A sample schema cannot contain more than 65535 values.")

    key_indexes = {key: index for index, key in enumerate(keys)}
    validity_size = (len(keys) + 7) // 8
    payload = bytearray(
        struct.pack(
            "<BIIIH",
            SAMPLE_PAYLOAD_VERSION,
            schema_id,
            sequence,
            len(frames),
            len(keys),
        )
    )
    for elapsed, values in frames:
        validity = bytearray(validity_size)
        numeric_values: dict[int, float] = {}
        for key, value in values.items():
            index = key_indexes.get(key)
            if index is None or not isinstance(value, (bool, int, float)):
                continue
            validity[index // 8] |= 1 << (index % 8)
            numeric_values[index] = float(value)
        payload.extend(struct.pack("<d", float(elapsed)))
        payload.extend(validity)
        for index in range(len(keys)):
            if index in numeric_values:
                payload.extend(struct.pack("<d", numeric_values[index]))
    return bytes(payload)


def frame_sample_payload(payload: bytes) -> bytes:
    return bytes((SAMPLE_FRAME_MARKER,)) + struct.pack("<I", len(payload)) + payload

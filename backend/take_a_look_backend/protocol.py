from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any


PROTOCOL_VERSION = 1


@dataclass(frozen=True)
class ProtocolError(Exception):
    code: str
    message: str
    details: object | None = None


def parse_request(line: str) -> tuple[object, str, dict[str, object]]:
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
    method = raw.get("method")
    if not isinstance(method, str) or not method:
        raise ProtocolError("invalid_request", "Method must be a non-empty string.")
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


def event(name: str, params: object) -> dict[str, object]:
    return {"v": PROTOCOL_VERSION, "event": name, "params": params}


def encode(message: Mapping[str, Any]) -> str:
    return json.dumps(message, ensure_ascii=False, separators=(",", ":"), allow_nan=False)

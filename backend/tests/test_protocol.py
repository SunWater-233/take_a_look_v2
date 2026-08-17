from __future__ import annotations

import unittest

import json
import struct

from take_a_look_backend.protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    encode,
    encode_sample_batch,
    error_response,
    event,
    parse_request,
    response,
)


class ProtocolTests(unittest.TestCase):
    def test_parses_versioned_request(self) -> None:
        request_id, method, params = parse_request('{"v":2,"id":7,"method":"getState","params":{}}')

        self.assertEqual(request_id, 7)
        self.assertEqual(method, "getState")
        self.assertEqual(params, {})

    def test_rejects_invalid_version_and_params(self) -> None:
        with self.assertRaisesRegex(ProtocolError, "version"):
            parse_request('{"v":1,"id":1,"method":"getState"}')
        with self.assertRaisesRegex(ProtocolError, "Params"):
            parse_request('{"v":2,"id":1,"method":"getState","params":[]}')

    def test_response_and_event_keep_the_protocol_version(self) -> None:
        self.assertEqual(response("a", {"ok": True})["v"], PROTOCOL_VERSION)
        self.assertEqual(event("samples", {})["event"], "samples")
        self.assertEqual(error_response("a", ProtocolError("bad", "No"))["error"], {"code": "bad", "message": "No"})

    def test_sample_batch_uses_schema_order_and_validity_bits(self) -> None:
        payload = encode_sample_batch(
            7,
            11,
            ["speed", "enabled", "missing"],
            [
                (0.25, {"speed": 12.5, "enabled": True}),
                (0.50, {"enabled": False}),
            ],
        )

        header = struct.unpack_from("<BIIIH", payload)
        self.assertEqual(header, (1, 7, 11, 2, 3))
        offset = struct.calcsize("<BIIIH")
        self.assertEqual(struct.unpack_from("<d", payload, offset)[0], 0.25)
        offset += 8
        self.assertEqual(payload[offset], 0b011)
        offset += 1
        self.assertEqual(struct.unpack_from("<dd", payload, offset), (12.5, 1.0))
        offset += 16
        self.assertEqual(struct.unpack_from("<d", payload, offset)[0], 0.5)
        offset += 8
        self.assertEqual(payload[offset], 0b010)
        offset += 1
        self.assertEqual(struct.unpack_from("<d", payload, offset)[0], 0.0)
        self.assertEqual(offset + 8, len(payload))

    def test_wire_encoding_is_ascii_safe_and_preserves_unicode(self) -> None:
        payload = encode(event("log", {"message": "探针已连接"}))

        self.assertTrue(payload.isascii())
        self.assertEqual(json.loads(payload)["params"]["message"], "探针已连接")

from __future__ import annotations

import unittest

from take_a_look_backend.protocol import PROTOCOL_VERSION, ProtocolError, error_response, event, parse_request, response


class ProtocolTests(unittest.TestCase):
    def test_parses_versioned_request(self) -> None:
        request_id, method, params = parse_request('{"v":1,"id":7,"method":"getState","params":{}}')

        self.assertEqual(request_id, 7)
        self.assertEqual(method, "getState")
        self.assertEqual(params, {})

    def test_rejects_invalid_version_and_params(self) -> None:
        with self.assertRaisesRegex(ProtocolError, "version"):
            parse_request('{"v":2,"id":1,"method":"getState"}')
        with self.assertRaisesRegex(ProtocolError, "Params"):
            parse_request('{"v":1,"id":1,"method":"getState","params":[]}')

    def test_response_and_event_keep_the_protocol_version(self) -> None:
        self.assertEqual(response("a", {"ok": True})["v"], PROTOCOL_VERSION)
        self.assertEqual(event("samples", {})["event"], "samples")
        self.assertEqual(error_response("a", ProtocolError("bad", "No"))["error"], {"code": "bad", "message": "No"})

import base64
import hashlib
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from active_agent.im import IMClient, IMError


ROOM = "room-11111111-1111-4111-8111-111111111111"
ATTACHMENT = "attachment-22222222-2222-4222-8222-222222222222"
ROUTE = "/api/im/rooms/" + ROOM + "/attachments"


class NativeMediaClientTests(unittest.TestCase):
    def setUp(self):
        self.payload = b"authenticated media bytes\x00\xff"
        self.calls = []
        self.metadata_reads = 0
        self.mode = "normal"
        self.client = None
        case = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def answer(self, status, data, headers=None):
                raw = data if isinstance(data, bytes) else json.dumps(data).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(raw)))
                for key, value in (headers or {}).items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(raw)

            def capture(self):
                case.calls.append((self.command, self.path, self.headers.get("Authorization")))
                if self.headers.get("Authorization") != "Bearer independent-media-test":
                    self.answer(401, {"error": {"code": "unauthorized"}})
                    return False
                return True

            def do_GET(self):
                if not self.capture():
                    return
                if self.path == ROUTE + "/" + ATTACHMENT:
                    case.metadata_reads += 1
                    if case.mode in {"flat_denied", "unsafe_error_code"}:
                        code = "not_a_member" if case.mode == "flat_denied" else "private unsafe error text"
                        self.answer(403, {"code": code, "error": "private metadata details"})
                        return
                    if case.mode == "revoked" and case.metadata_reads > 1:
                        self.answer(403, {"error": {"code": "not_a_member"}})
                        return
                    metadata = case.metadata()
                    if case.mode == "wrong_room":
                        metadata["room_id"] = "room-other"
                    if case.mode == "deleted":
                        metadata["status"] = "deleted"
                    if case.mode == "changed" and case.metadata_reads > 1:
                        metadata["sha256"] = "f" * 64
                    if case.mode == "identity_metadata":
                        case.client.token = "new-principal"
                    self.answer(200, {"attachment": metadata})
                elif self.path == ROUTE + "/" + ATTACHMENT + "/content":
                    if case.mode == "redirect":
                        self.answer(302, b"", {"Location": "/forbidden-destination?token=must-not-be-followed"})
                        return
                    if case.mode == "media_denied":
                        self.answer(403, {"code": "not_a_member", "message": "private error must not surface"})
                        return
                    data = case.payload
                    if case.mode == "corrupt":
                        data = b"X" + data[1:]
                    if case.mode == "short":
                        data = data[:-1]
                    if case.mode == "extra":
                        data += b"X"
                    if case.mode == "identity_bytes":
                        case.client.token = "new-principal"
                    if case.mode == "no_length_extra":
                        self.send_response(200)
                        self.end_headers()
                        self.wfile.write(data + b"X")
                        return
                    self.answer(200, data, {"Content-Type": "application/octet-stream"})
                else:
                    self.answer(500, {"error": {"code": "unexpected_route"}})

            def do_POST(self):
                if not self.capture():
                    return
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path == ROUTE:
                    case.assertEqual(set(body), {"client_id", "filename", "mime_type", "data_base64"})
                    case.assertEqual(body["client_id"], "stable-upload")
                    case.assertEqual(base64.b64decode(body["data_base64"]), case.payload)
                    metadata = case.metadata()
                    if case.mode == "upload_bad_hash":
                        metadata["sha256"] = "a" * 64
                    self.answer(200, {"attachment": metadata, "duplicate": len(case.calls) > 1})
                elif self.path.endswith("/messages"):
                    case.sent = body
                    self.answer(200, {"message": {"id": "msg-existing", "kind": "voice", "voice": body["voice"]}})
                else:
                    self.answer(500, {})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
        self.thread.start()
        self.client = IMClient("http://127.0.0.1:%s" % self.server.server_port, "independent-media-test")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def metadata(self):
        return {"id": ATTACHMENT, "room_id": ROOM, "status": "active", "size": len(self.payload),
                "sha256": hashlib.sha256(self.payload).hexdigest(),
                "download_path": "https://untrusted.invalid/steal?access_token=ignored"}

    def test_binary_download_larger_than_json_limit_is_bounded_and_verified(self):
        self.payload = b"a" * 9_000_000
        self.assertEqual(self.client.download_attachment(ROOM, ATTACHMENT), self.payload)
        self.assertEqual(self.metadata_reads, 2)
        self.assertEqual([path for _, path, _ in self.calls], [ROUTE + "/" + ATTACHMENT,
            ROUTE + "/" + ATTACHMENT + "/content", ROUTE + "/" + ATTACHMENT])
        self.assertTrue(all(auth == "Bearer independent-media-test" for _, _, auth in self.calls))

    def test_upload_recovers_stable_intent_and_does_not_send_a_message(self):
        first = self.client.upload_attachment(ROOM, self.payload, filename="memo.wav", client_id="stable-upload", mime_type="audio/wav")
        second = self.client.upload_attachment(ROOM, self.payload, filename="memo.wav", client_id="stable-upload", mime_type="audio/wav")
        self.assertEqual(first["id"], second["id"])
        self.assertEqual([(method, path) for method, path, _ in self.calls], [("POST", ROUTE)] * 2)

    def test_corrupt_upload_receipt_is_rejected(self):
        self.mode = "upload_bad_hash"
        with self.assertRaises(IMError) as found:
            self.client.upload_attachment(ROOM, self.payload, filename="x", client_id="stable-upload")
        self.assertEqual(found.exception.code, "attachment_integrity")

    def test_small_caller_limit_rejects_before_fetching_content(self):
        with self.assertRaises(IMError) as found:
            self.client.download_attachment(ROOM, ATTACHMENT, max_bytes=1)
        self.assertEqual(found.exception.status, 413)
        self.assertEqual(len(self.calls), 1)

    def test_integrity_checks_reject_corrupt_truncated_and_oversized_streams(self):
        for mode in ["corrupt", "short", "extra", "no_length_extra"]:
            with self.subTest(mode=mode):
                self.mode = mode
                with self.assertRaises(IMError) as found:
                    self.client.download_attachment(ROOM, ATTACHMENT)
                self.assertEqual(found.exception.code, "attachment_integrity")

    def test_scope_deleted_and_revoked_metadata_never_returns_bytes(self):
        for mode, status in [("wrong_room", 502), ("deleted", 410), ("revoked", 403), ("changed", 409)]:
            with self.subTest(mode=mode):
                self.mode, self.metadata_reads = mode, 0
                with self.assertRaises(IMError) as found:
                    self.client.download_attachment(ROOM, ATTACHMENT)
                self.assertEqual(found.exception.status, status)

    def test_principal_turnover_during_metadata_or_binary_read_rejects_old_data(self):
        for mode in ["identity_metadata", "identity_bytes"]:
            with self.subTest(mode=mode):
                self.client.token = "independent-media-test"
                self.mode = mode
                self.calls.clear()
                with self.assertRaises(IMError) as found:
                    self.client.download_attachment(ROOM, ATTACHMENT)
                self.assertEqual(found.exception.code, "identity_changed")
                self.assertTrue(all(auth == "Bearer independent-media-test" for _, _, auth in self.calls))

    def test_redirect_does_not_forward_credential_and_error_text_stays_private(self):
        for mode, status, code in [("redirect", 302, "request_failed"), ("media_denied", 403, "not_a_member")]:
            self.mode = mode
            with self.assertRaises(IMError) as found:
                self.client.download_attachment(ROOM, ATTACHMENT)
            self.assertEqual((found.exception.status, found.exception.code), (status, code))
            self.assertNotIn("private error", str(found.exception))
            self.assertFalse(any("forbidden-destination" in path for _, path, _ in self.calls))

    def test_real_server_flat_json_errors_preserve_only_safe_machine_codes(self):
        for mode, code in [("flat_denied", "not_a_member"), ("unsafe_error_code", "request_failed")]:
            self.mode = mode
            with self.assertRaises(IMError) as found:
                self.client.download_attachment(ROOM, ATTACHMENT)
            self.assertEqual((found.exception.status, found.exception.code), (403, code))
            self.assertNotIn("private", str(found.exception))

    def test_invalid_inputs_do_not_make_requests(self):
        for args in [("room-../other", ATTACHMENT), (ROOM, "https://bad.invalid"), (ROOM, "attachment-a?token=x")]:
            with self.assertRaises(ValueError):
                self.client.download_attachment(*args)
        for limit in [0, True, IMClient.MAX_ATTACHMENT_BYTES + 1, 1.5]:
            with self.assertRaises(ValueError):
                self.client.download_attachment(ROOM, ATTACHMENT, max_bytes=limit)
        for data in [b"", "audio", memoryview(b"x" * (IMClient.MAX_ATTACHMENT_BYTES + 1))]:
            with self.assertRaises(ValueError):
                self.client.upload_attachment(ROOM, data, filename="memo.wav", client_id="stable-upload")
        self.assertEqual(self.calls, [])

    def test_voice_send_uses_only_coordinate_and_preserves_reply_and_mentions(self):
        result = self.client.send_voice(ROOM, ATTACHMENT, client_id="stable-message", reply_to="msg-parent", mentions=["agent-peer"])
        self.assertEqual(result["message"]["kind"], "voice")
        self.assertEqual(self.sent, {"client_id": "stable-message", "content": "", "voice": {"attachment_id": ATTACHMENT},
            "reply_to": "msg-parent", "mentions": ["agent-peer"]})
        self.assertNotIn("data_base64", json.dumps(self.sent))


if __name__ == "__main__":
    unittest.main()

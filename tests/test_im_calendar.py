"""Calendar SDK transport tests using an isolated, synthetic local HTTP service."""
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from active_agent.im import IMClient, IMError


ROOM = "room-11111111-1111-4111-8111-111111111111"
EVENT = "calendar-22222222-2222-4222-8222-222222222222"


class CalendarSDKTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.reply = {"event": {"id": EVENT, "revision": 2}, "series": {"id": EVENT, "revision": 2}}
        self.status = 200
        self.change_identity = False
        case = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def respond(self):
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length)) if length else None
                case.calls.append((self.command, self.path, body, self.headers.get("Authorization")))
                if case.change_identity:
                    case.client.token = "synthetic-next-identity"
                raw = json.dumps(case.reply).encode()
                self.send_response(case.status)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            do_GET = do_POST = do_PATCH = do_DELETE = respond

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
        self.thread.start()
        self.client = IMClient("http://127.0.0.1:%s" % self.server.server_port, "synthetic-calendar-member")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_queries_encode_offsets_text_and_opaque_cursor_without_local_expansion(self):
        self.client.list_calendar_events(q="企业 & Agent")
        self.assertEqual(parse_qs(urlsplit(self.calls[-1][1]).query), {"q": ["企业 & Agent"]})
        self.reply = {"occurrences": [], "next_cursor": "opaque/+==", "truncated": True}
        result = self.client.list_calendar_occurrences(from_time="2026-03-08T00:00:00-05:00",
            to_time="2026-03-09T00:00:00-04:00", timezone="America/New_York", limit=2, cursor="opaque/+==")
        self.assertEqual(result, self.reply)
        self.assertEqual(parse_qs(urlsplit(self.calls[-1][1]).query), {
            "from": ["2026-03-08T00:00:00-05:00"], "to": ["2026-03-09T00:00:00-04:00"],
            "timezone": ["America/New_York"], "limit": ["2"], "cursor": ["opaque/+=="]})
        self.assertEqual(len(self.calls), 2)

    def test_all_day_creation_preserves_dates_recurrence_and_stable_intent(self):
        recurrence = {"frequency": "monthly", "interval": 1,
                      "ordinal_weekday": {"ordinal": -1, "weekday": 5}, "count": 4}
        result = self.client.create_calendar_event(ROOM, title="月底复核", client_id="stable-calendar",
            all_day=True, timezone="Asia/Shanghai", start_date="2026-09-25", end_date="2026-09-26",
            recurrence=recurrence, attendee_ids=["human-1", "agent-1"])
        method, route, body, authorization = self.calls[-1]
        self.assertEqual((method, route), ("POST", "/api/im/rooms/" + ROOM + "/calendar"))
        self.assertEqual(authorization, "Bearer synthetic-calendar-member")
        self.assertEqual(body["recurrence"], recurrence)
        self.assertEqual(body["client_id"], "stable-calendar")
        self.assertEqual(body["end_date"], "2026-09-26")
        self.assertNotIn("starts_at", body)
        self.assertNotIn("ends_at", body)
        self.assertNotIn("actor_id", body)
        self.assertEqual(result, self.reply)

    def test_occurrence_read_edit_cancel_and_response_keep_scope_and_cas(self):
        instance = "server-instance/+=="
        self.client.read_calendar_event(EVENT, occurrence_id=instance)
        self.assertEqual(parse_qs(urlsplit(self.calls[-1][1]).query), {"occurrence_id": [instance]})
        result = self.client.update_calendar_event(EVENT, base_revision=3, client_id="edit-once",
            scope="occurrence", occurrence_id=instance, title="本次变更")
        self.assertEqual(result, self.reply)
        self.assertEqual(self.calls[-1][2], {"base_revision": 3, "client_id": "edit-once", "scope": "occurrence",
            "occurrence_id": instance, "title": "本次变更"})
        self.client.update_calendar_event(EVENT, base_revision=4, client_id="clear-repeat", scope="series", recurrence=None, reset_exceptions=True)
        self.assertIn("recurrence", self.calls[-1][2])
        self.assertIsNone(self.calls[-1][2]["recurrence"])
        self.assertIs(self.calls[-1][2]["reset_exceptions"], True)
        self.client.cancel_calendar_event(EVENT, base_revision=5, client_id="cancel-once", scope="occurrence", occurrence_id=instance)
        self.assertEqual(self.calls[-1][:2], ("DELETE", "/api/im/calendar/" + EVENT))
        self.assertEqual(self.calls[-1][2]["scope"], "occurrence")
        self.client.respond_calendar_event(EVENT, "tentative", base_revision=6, client_id="respond-once", scope="series")
        self.assertEqual(self.calls[-1][:2], ("POST", "/api/im/calendar/" + EVENT + "/respond"))
        self.assertEqual(self.calls[-1][2], {"base_revision": 6, "client_id": "respond-once", "scope": "series", "response": "tentative"})

    def test_invalid_local_arguments_never_send_and_unknown_outcomes_never_retry(self):
        invalid = [
            lambda: self.client.read_calendar_event("calendar-../foreign"),
            lambda: self.client.update_calendar_event(EVENT, base_revision=True, title="bad revision"),
            lambda: self.client.update_calendar_event(EVENT, base_revision=1, actor_id="another-person"),
            lambda: self.client.cancel_calendar_event(EVENT, base_revision=1, client_id=None),
            lambda: self.client.list_calendar_occurrences(from_time="start", to_time="end", limit=501),
        ]
        for call in invalid:
            with self.assertRaises(ValueError):
                call()
        self.assertEqual(self.calls, [])
        self.status, self.reply = 503, {"code": "outcome_pending", "error": "private diagnostic"}
        with self.assertRaises(IMError) as error:
            self.client.cancel_calendar_event(EVENT, base_revision=1, client_id="stable-cancel", scope="series")
        self.assertEqual(error.exception.code, "outcome_pending")
        self.assertNotIn("private", str(error.exception))
        self.assertEqual(len(self.calls), 1)

    def test_response_is_fenced_when_identity_changes_during_http(self):
        self.change_identity = True
        with self.assertRaises(IMError) as error:
            self.client.read_calendar_event(EVENT)
        self.assertEqual(error.exception.code, "identity_changed")
        self.assertEqual(len(self.calls), 1)


if __name__ == "__main__":
    unittest.main()

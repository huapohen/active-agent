"""Calendar SDK against the real Node server in an isolated temporary workspace."""
import unittest

from active_agent.im import IMClient, IMError
from tests import test_im_media_node as node_fixture


class NativeCalendarNodeIntegrationTests(unittest.TestCase):
    # Reuse only the isolated server lifecycle, not the unrelated media tests.
    setUpClass = classmethod(node_fixture.NativeMediaNodeIntegrationTests.setUpClass.__func__)
    stop_process = classmethod(node_fixture.NativeMediaNodeIntegrationTests.stop_process.__func__)

    def setUp(self):
        self.people = []
        for name, kind in [("Calendar Human", "human"), ("Calendar Agent", "agent"), ("Calendar Outsider", "agent")]:
            result = self.admin.request("POST", "/admin/principals", {"name": name, "kind": kind})
            self.people.append((IMClient(self.base, result["token"], timeout=5), result["principal"]["id"]))
        self.human, self.agent, self.outsider = [entry[0] for entry in self.people]
        self.room = self.human.request("POST", "/rooms", {"name": "Isolated SDK calendar"})["room"]["id"]
        self.human.request("POST", "/rooms/" + self.room + "/members", {"principal_id": self.people[1][1]})

    def test_real_http_recurring_all_day_human_rsvp_agent_edit_cancel_and_visibility(self):
        creation = dict(title="SDK weekly planning", client_id="sdk-weekly", all_day=True, timezone="Asia/Shanghai",
            start_date="2026-09-07", end_date="2026-09-08", recurrence={"frequency": "weekly", "weekdays": [1], "count": 3},
            attendee_ids=[self.people[0][1], self.people[1][1]])
        first = self.agent.create_calendar_event(self.room, **creation)
        event_id = first["event"]["id"]
        self.assertEqual(first["event"]["created_by"], self.people[1][1])
        self.assertTrue(self.agent.create_calendar_event(self.room, **creation)["duplicate"])
        self.assertEqual(self.human.list_calendar_events(q="SDK weekly planning")["events"][0]["id"], event_id)
        window = dict(from_time="2026-09-01T00:00:00+08:00", to_time="2026-10-01T00:00:00+08:00", timezone="Asia/Shanghai", limit=2)
        page = self.human.list_calendar_occurrences(**window)
        self.assertEqual(len(page["occurrences"]), 2)
        self.assertTrue(page["truncated"])
        self.assertEqual(len(self.human.list_calendar_occurrences(**window, cursor=page["next_cursor"])["occurrences"]), 1)
        occurrence_id = page["occurrences"][0]["occurrence_id"]
        self.assertEqual(self.human.read_calendar_event(event_id, occurrence_id=occurrence_id)["event"]["start_date"], "2026-09-07")
        response = self.human.respond_calendar_event(event_id, "accepted", base_revision=1, client_id="sdk-rsvp",
            scope="occurrence", occurrence_id=occurrence_id)
        self.assertEqual(response["event"]["responses"][self.people[0][1]], "accepted")
        changed = self.agent.update_calendar_event(event_id, base_revision=2, client_id="sdk-edit", scope="occurrence",
            occurrence_id=occurrence_id, title="SDK this occurrence")
        self.assertEqual(changed["event"]["title"], "SDK this occurrence")
        self.assertEqual(changed["series"]["title"], "SDK weekly planning")
        with self.assertRaises(IMError) as stale:
            self.human.list_calendar_occurrences(**window, cursor=page["next_cursor"])
        self.assertEqual(stale.exception.code, "stale_cursor")
        canceled = self.agent.cancel_calendar_event(event_id, base_revision=3, client_id="sdk-cancel-one",
            scope="occurrence", occurrence_id=occurrence_id)
        self.assertEqual(canceled["event"]["status"], "cancelled")
        self.assertEqual(canceled["series"]["status"], "scheduled")
        with self.assertRaises(IMError) as denied:
            self.outsider.read_calendar_event(event_id)
        self.assertEqual((denied.exception.status, denied.exception.code), (403, "not_a_member"))
        self.assertEqual(self.outsider.list_calendar_occurrences(**window)["occurrences"], [])

    def test_real_http_invalid_all_day_has_no_effect_and_legacy_timed_event_still_works(self):
        with self.assertRaises(IMError) as invalid:
            self.human.create_calendar_event(self.room, title="Invalid fake midnight", client_id="sdk-invalid", all_day=True,
                start_date="2026-09-07", end_date="2026-09-08", starts_at="2026-09-07T00:00:00Z", ends_at="2026-09-08T00:00:00Z")
        self.assertEqual(invalid.exception.status, 422)
        self.assertEqual(self.human.list_calendar_events(q="Invalid fake midnight")["events"], [])
        created = self.agent.create_calendar_event(self.room, title="SDK timed", client_id="sdk-timed",
            starts_at="2026-09-07T10:00:00+08:00", ends_at="2026-09-07T11:00:00+08:00")
        self.assertFalse(created["event"]["all_day"])
        updated = self.agent.update_calendar_event(created["event"]["id"], base_revision=1, title="SDK timed update")
        self.assertEqual(updated["event"]["title"], "SDK timed update")


if __name__ == "__main__":
    unittest.main()

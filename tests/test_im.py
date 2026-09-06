import copy
import json
import unittest
from dataclasses import replace

from active_agent.config import Settings
from active_agent.im import IMAgent, IMClient, IMError, SYSTEM
from active_agent.llm import ModelError


class Model:
    def __init__(self, output=None):
        self.calls = []
        self.output = output or {"action": "reply", "content": "Draft ready for review.",
            "rationale": "The task asks for a specification.", "mentions": [],
            "artifact": {"title": "Specification", "content": "# Acceptance\n\nVerify reconnect."}}

    def complete_json(self, system, user):
        self.calls.append((system, json.loads(user)))
        if isinstance(self.output, Exception):
            raise self.output
        return self.output


class RoomService:
    """A receipt service fixture: completed work survives replacing the worker."""
    def __init__(self, eligible=True):
        self.eligible = eligible
        self.receipt = None
        self.finish_calls = []
        self.ambiguous = False
        self.reject = False
        self.kind = "agent"
        self.context = {"instructions": SYSTEM, "room": {"id": "room-1"},
            "participants": [{"principal_id": "person-1"}, {"principal_id": "agent-1"}],
            "messages": [{"id": "m-1", "content": "Draft an acceptance spec"}],
            "documents": [{"id": "doc-1", "revision": 7, "content_hash": "abc", "content": "Reconnect safely."}],
            "tasks": [{"id": "task-1", "assignee_id": "agent-1", "status": "open"}]}

    def request(self, method, path, body=None):
        if path == "/me":
            return {"principal": {"id": "agent-1", "kind": self.kind}}
        if path == "/rooms":
            return {"rooms": [{"id": "room-1"}]}
        if path.endswith("/claim"):
            if not self.eligible or self.receipt:
                return {"turn": None}
            return {"turn": {"id": "turn-1", "lease_token": "test-fence"}, "context": copy.deepcopy(self.context)}
        if path.endswith("/finish"):
            self.finish_calls.append(copy.deepcopy(body))
            if self.reject:
                raise IMError(409)
            self.receipt = {"turn": {"id": "turn-1", "status": body["action"]}}
            if self.ambiguous and len(self.finish_calls) == 1:
                # The server committed the reply; the network lost its response.
                raise IMError(503)
            return self.receipt
        raise AssertionError(path)


class NativeIMTests(unittest.TestCase):
    def setUp(self):
        self.settings = replace(Settings(), model_name="test-model", im_token="test-principal")

    def test_idle_room_does_not_call_model(self):
        model = Model()
        result = IMAgent(self.settings, RoomService(False), model).cycle()
        self.assertEqual(result["checked"], 0)
        self.assertEqual(model.calls, [])

    def test_exact_visible_context_used_and_output_cannot_impersonate(self):
        service, model = RoomService(), Model()
        model.output.update({"actor_id": "person-1", "role": "owner", "tools": ["delete_everything"]})
        IMAgent(self.settings, service, model).cycle()
        self.assertEqual(model.calls[0], (SYSTEM, service.context))
        submitted = service.finish_calls[0]
        self.assertNotIn("actor_id", submitted)
        self.assertNotIn("tools", submitted)
        self.assertEqual(submitted["artifact"]["title"], "Specification")
        self.assertNotIn("api_key", json.dumps(submitted))

    def test_ambiguous_publication_retries_same_result_without_new_inference(self):
        service, model = RoomService(), Model()
        service.ambiguous = True
        IMAgent(self.settings, service, model).cycle()
        self.assertEqual(len(model.calls), 1)
        self.assertEqual(service.finish_calls[0], service.finish_calls[1])
        restarted = IMAgent(self.settings, service, model)
        self.assertEqual(restarted.cycle()["checked"], 0)
        self.assertEqual(len(model.calls), 1)

    def test_stale_lease_discards_result_without_unscoped_fallback(self):
        service = RoomService()
        service.reject = True
        result = IMAgent(self.settings, service, Model()).cycle()
        self.assertEqual(result["results"][0]["state"], "cancelled")
        self.assertIsNone(service.receipt)
        self.assertEqual(len(service.finish_calls), 1)

    def test_invalid_or_incomplete_provider_result_becomes_visible_blocked_record(self):
        for output in [ModelError("provider-secret-must-never-leak"), {"action": "reply", "content": "partial"}]:
            service = RoomService()
            IMAgent(self.settings, service, Model(output)).cycle()
            self.assertEqual(service.receipt["turn"]["status"], "blocked")
            self.assertNotIn("provider-secret", json.dumps(service.finish_calls))
            self.assertEqual(service.finish_calls[0]["content"], "")

    def test_only_roster_members_can_be_handoff_targets(self):
        for mentions in [["stranger"], "person-1", [None]]:
            with self.assertRaises(ModelError):
                IMAgent.validate({"action": "reply", "content": "Hello", "rationale": "handoff", "mentions": mentions}, RoomService().context)

    def test_artifacts_are_bounded_and_only_supported_for_reply(self):
        with self.assertRaises(ModelError):
            IMAgent.validate({"action": "silent", "rationale": "done", "artifact": {"title": "x", "content": "hidden work"}}, {})
        with self.assertRaises(ModelError):
            IMAgent.validate({"action": "reply", "content": "draft", "rationale": "work", "artifact": {"title": "x", "content": "x" * 60001}}, {})

    def test_human_credential_not_silently_used_as_agent(self):
        service, model = RoomService(), Model()
        service.kind = "human"
        with self.assertRaises(ValueError):
            IMAgent(self.settings, service, model).cycle()
        self.assertEqual(model.calls, [])

    def test_missing_model_is_visible_and_does_not_fabricate_output(self):
        service = RoomService()
        IMAgent(self.settings, service).cycle()
        self.assertEqual(service.receipt["turn"]["status"], "blocked")
        self.assertIsNone(service.finish_calls[0]["artifact"])
        self.assertEqual(service.finish_calls[0]["reasoning_effort"], "none")

    def test_reclaimed_work_never_silently_switches_model_configuration(self):
        service, model = RoomService(), Model()
        service.context.update({"model": "previous-model", "reasoning_effort": "high"})
        IMAgent(self.settings, service, model).cycle()
        self.assertEqual(model.calls, [])
        self.assertEqual(service.finish_calls[0]["action"], "blocked")
        self.assertEqual(service.finish_calls[0]["model"], "previous-model")
        self.assertEqual(service.finish_calls[0]["reasoning_effort"], "high")

    def test_client_requires_distinct_credential_and_safe_service_url(self):
        with self.assertRaises(ValueError):
            IMClient("http://127.0.0.1:3218", "")
        for url in ["file:///etc/passwd", "http://name:secret@example.com", "http://example.com?token=x"]:
            with self.assertRaises(ValueError):
                IMClient(url, "credential")


if __name__ == "__main__":
    unittest.main()

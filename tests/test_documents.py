import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from active_agent.config import Settings
from active_agent.documents import DocumentAgent, Checkpoints, DocumentError
from active_agent.llm import ModelError, OpenAICompatibleModel


class Client:
    def __init__(self):
        self.source = {"id": "doc-1", "title": "Plan", "content": "## Acceptance\nShould be fast.",
                       "revision": 1, "content_hash": "hash-1", "contract": None}
        self.mission = {"id": "mission-1", "revision": 1, "contract": {"kind": "mission", "status": "active",
            "quiet_seconds": 5, "source_document_id": "doc-1", "objective": "Make acceptance measurable"}}
        self.records, self.posts = [], []
        self.fail_publish = False

    def request(self, method, path, body=None):
        if path == "":
            return {"documents": copy.deepcopy([self.source, self.mission] + self.records)}
        if path == "/worker":
            return {}
        if path == "/runs":
            if self.fail_publish:
                raise DocumentError(409, "stale_run")
            self.posts.append(body)
            result = {"id": "run-1", "contract": {**body, "kind": "proposal", "status": "pending"}}
            self.records.append(result)
            return {"document": result}
        raise AssertionError(path)


class Model:
    def __init__(self):
        self.calls = 0
        self.error = False

    def complete_json(self, system, user):
        self.calls += 1
        if self.error:
            raise ModelError("provider unavailable")
        return {"action": "propose", "confidence": 0.9, "rationale": "The acceptance condition needs a test.",
                "evidence_quotes": ["Should be fast."], "replacement": "## Acceptance\nVerify document sync in a two-client session."}


class DocumentAgentTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.now = 1000
        self.client, self.model = Client(), Model()
        self.settings = Settings(db_path=Path(self.tmp.name) / "worker.db", model_name="test-model", model_reasoning_effort="medium")
        self.agent = DocumentAgent(self.settings, self.client, self.model, lambda: self.now)

    def tearDown(self):
        self.tmp.cleanup()

    def test_debounce_resets_on_edit_then_publishes_once(self):
        self.agent.cycle()
        self.now += 4
        self.client.source["revision"] += 1
        self.agent.cycle()
        self.now += 4
        self.assertEqual(self.agent.cycle()["checked"], 0)
        self.now += 2
        self.assertEqual(self.agent.cycle()["results"][0]["state"], "propose")
        self.now += 50
        self.agent.cycle()
        self.assertEqual(self.model.calls, 1)
        self.assertEqual(self.client.posts[0]["reasoning_effort"], "medium")

    def test_restart_and_lost_checkpoint_recover_from_visible_document(self):
        self.agent.cycle(); self.now += 6; self.agent.cycle()
        fresh = Settings(db_path=Path(self.tmp.name) / "fresh.db", model_name="test-model")
        restarted = DocumentAgent(fresh, self.client, self.model, lambda: self.now)
        restarted.cycle(); self.now += 6; restarted.cycle()
        self.assertEqual(self.model.calls, 1)

    def test_model_output_is_discarded_if_document_changed_during_thinking(self):
        self.client.fail_publish = True
        self.agent.cycle(); self.now += 6
        self.assertEqual(self.agent.cycle()["results"][0]["state"], "stale")
        self.assertEqual(self.client.posts, [])

    def test_paused_mission_never_calls_model(self):
        self.client.mission["contract"]["status"] = "paused"
        self.agent.cycle(); self.now += 100; self.agent.cycle()
        self.assertEqual(self.model.calls, 0)

    def test_model_failure_retries_with_backoff_and_stops_after_three_attempts(self):
        self.model.error = True
        self.agent.cycle(); self.now += 6; self.agent.cycle()
        self.now += 1; self.assertEqual(self.agent.cycle()["checked"], 0)
        for _ in range(3):
            self.now += 301; self.agent.cycle()
        self.assertEqual(self.model.calls, 3)
        self.assertEqual(self.client.posts[-1]["action"], "blocked")

    def test_accepted_write_does_not_trigger_agent_feedback_loop(self):
        self.agent.cycle(); self.now += 6; self.agent.cycle()
        self.client.source["revision"] = 2
        self.client.source["content_hash"] = "hash-2"
        self.client.records[0]["contract"].update(status="accepted", result_revision=2)
        self.now += 6; self.agent.cycle(); self.now += 6; self.agent.cycle()
        self.assertEqual(self.model.calls, 1)

    def test_foreign_worker_lease_prevents_double_evaluation(self):
        self.agent.checkpoints.claim("other", self.now, 100)
        self.assertEqual(self.agent.cycle()["reason"], "leased")
        self.now += 101
        self.assertNotIn("reason", self.agent.cycle())

    def test_invalid_evidence_and_nan_are_rejected(self):
        raw = self.model.complete_json("", "")
        raw["evidence_quotes"] = ["made-up source"]
        with self.assertRaises(ModelError):
            self.agent.validate(raw, self.client.source["content"])
        raw["evidence_quotes"] = ["Should be fast."]
        raw["confidence"] = float("nan")
        with self.assertRaises(ModelError):
            self.agent.validate(raw, self.client.source["content"])

    def test_request_preserves_explicit_model_and_reasoning_without_temperature(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, *args): return b'{"choices":[{"message":{"content":"{\\"ok\\":true}"}}]}'
        with patch("urllib.request.urlopen", return_value=Response()) as request:
            model = OpenAICompatibleModel("test-only", "https://provider.test/v1", "gpt-6-astra", reasoning_effort="medium")
            self.assertTrue(model.complete_json("system", "user")["ok"])
            payload = json.loads(request.call_args.args[0].data)
            self.assertEqual(payload["model"], "gpt-6-astra")
            self.assertEqual(payload["reasoning_effort"], "medium")
            self.assertNotIn("temperature", payload)


if __name__ == "__main__":
    unittest.main()

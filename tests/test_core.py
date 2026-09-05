import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
import tempfile
import unittest

from active_agent.config import Settings, save_model_key
from active_agent.engine import ActiveAgent
from active_agent.llm import OpenAICompatibleModel
from active_agent.models import IncomingEvent, MissionSpec, Mode
from active_agent.store import Store


class ActiveAgentTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "test.db")
        self.settings = Settings(db_path=Path(self.tmp.name) / "test.db", min_silence_seconds=0)
        self.agent = ActiveAgent(self.store, self.settings)

    def tearDown(self):
        self.tmp.cleanup()

    def test_mention_creates_recoverable_mission(self):
        result = self.agent.ingest(IncomingEvent("group-1", "user-1", "@AA 帮我留意项目资源是否不足", sender_name="小王"))
        self.assertTrue(result["accepted"])
        mission = result["created_mission"]
        self.assertEqual(mission["mode"], "watch")
        self.assertEqual(mission["risk"], "high")
        self.assertEqual(len(self.store.evidence(mission["mission_id"])), 1)

    def test_duplicate_im_event_is_idempotent(self):
        event = IncomingEvent("group-1", "user-1", "same", event_id="external-event-1")
        self.assertTrue(self.agent.ingest(event)["accepted"])
        self.assertFalse(self.agent.ingest(event)["accepted"])

    def test_relevant_message_becomes_evidence_and_notification(self):
        mission = self.agent.create_mission(MissionSpec("group-1", "user-1", "支付服务上线阻塞", Mode.WATCH))
        self.agent.ingest(IncomingEvent("group-1", "user-2", "支付服务上线仍被证书问题阻塞"))
        past = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
        self.store.update_mission(mission["mission_id"], next_check_at=past)
        result = self.agent.run_cycle()
        self.assertEqual(result["results"][0]["action"], "notify")
        self.assertEqual(len(self.store.pending_outbox()), 1)

    def test_orchestration_requests_approval(self):
        spec = MissionSpec("group-1", "agent-1", "协调团队完成迁移", Mode.ORCHESTRATOR, metadata={"evidence_threshold": 1})
        mission = self.agent.create_mission(spec)
        self.store.add_evidence(mission["mission_id"], "任务范围已经明确")
        result = self.agent.run_cycle()
        approval_id = result["results"][0]["approval_id"]
        self.assertIsNotNone(approval_id)
        self.assertEqual(self.store.get_mission(mission["mission_id"])["status"], "waiting_approval")
        self.agent.approve(approval_id, True, "owner")
        self.assertEqual(self.store.get_mission(mission["mission_id"])["status"], "active")

    def test_model_url_accepts_versioned_endpoint(self):
        model = OpenAICompatibleModel("secret", "https://example.test/compatible-mode/v1", "qwen")
        self.assertEqual(model.chat_url, "https://example.test/compatible-mode/v1/chat/completions")

    def test_secret_writer_updates_ignored_env_shape(self):
        path = Path(self.tmp.name) / ".env"
        path.write_text("AA_MODEL_NAME=qwen\nAA_MODEL_API_KEY=old\n", encoding="utf-8")
        save_model_key("test-only", path)
        self.assertIn("AA_MODEL_API_KEY=test-only", path.read_text(encoding="utf-8"))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_quiet_window_prevents_interrupting_active_chat(self):
        settings = Settings(db_path=Path(self.tmp.name) / "test.db", min_silence_seconds=300)
        agent = ActiveAgent(self.store, settings)
        mission = agent.create_mission(MissionSpec("group-1", "user-1", "支付上线阻塞", Mode.WATCH))
        agent.ingest(IncomingEvent("group-1", "user-2", "支付上线仍然阻塞"))
        self.assertGreater(self.store.get_mission(mission["mission_id"])["next_check_at"], datetime.now(timezone.utc).isoformat())
        self.assertEqual(agent.run_cycle()["checked"], 0)


if __name__ == "__main__":
    unittest.main()

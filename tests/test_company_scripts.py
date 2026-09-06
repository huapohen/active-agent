import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from active_agent.config import Settings

SCRIPTS = Path(__file__).parents[1] / "scripts"


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    # demo imports the existing local development helper as its CLI does.
    with patch.object(sys, "path", [str(SCRIPTS), *sys.path]):
        spec.loader.exec_module(module)
    return module


demo = load("demo_office_company")
verify = load("verify_company_model_actions")


class CompanyScriptTests(unittest.TestCase):
    def test_document_allowlist_cannot_stand_in_for_server_capability(self):
        policy = {"autonomy": {"allowed_operations": ["im_create_document"]}}
        for member in [policy, {**policy, "available_operations": ["im_create_document"]},
                       {**policy, "autonomy_available_operations": ["im_create_task"]}]:
            with self.assertRaisesRegex(ValueError, "does not yet advertise"):
                demo.available_native_actions(member)
        self.assertEqual(demo.available_native_actions({"autonomy_available_operations": ["im_create_task", "im_create_document"]}),
                         ["im_create_task", "im_create_document"])

    def fixture(self, folder, *, passed=False, evidence_room="room-fixture"):
        root = Path(folder)
        office = root / "data/office"
        office.mkdir(parents=True)
        (office / "admin.json").write_text(json.dumps({"token": "fixture-admin-secret"}))
        (office / "access.json").write_text(json.dumps({"human": {"token": "fixture-owner-secret"}}))
        (office / "demo-company.json").write_text(json.dumps({"base_url": "http://127.0.0.1:3218", "room_id": "room-fixture",
            "agents": {"product": {"principal_id": "agent-fixture", "name": "Product"}},
            "humans": {"engineering": {"principal_id": "human-reader", "account": {"username": "fixture-reader", "password": "fixture-password-secret"}}}}))
        output = root / "output.json"
        output.write_text(json.dumps({"room_id": evidence_room, "runs": [{"stage": "product", "passed": True}] if passed else []}))
        return root, output

    def settings(self):
        return Settings(model_name="gpt-6-astra", model_reasoning_effort="medium", model_api_key="fixture-model-secret")

    def test_completed_stage_is_rejected_before_any_client_or_login(self):
        with tempfile.TemporaryDirectory() as folder:
            root, output = self.fixture(folder, passed=True)
            before = output.read_text()
            with patch.object(verify, "ROOT", root), patch.object(verify, "OUTPUT", output), \
                 patch.object(verify.Settings, "from_env", return_value=self.settings()), patch.object(verify, "IMClient") as client:
                with self.assertRaisesRegex(ValueError, "already passed"):
                    verify.main("product")
                client.assert_not_called()
            self.assertEqual(output.read_text(), before)

    def test_foreign_evidence_scope_is_rejected_before_any_client_or_login(self):
        with tempfile.TemporaryDirectory() as folder:
            root, output = self.fixture(folder, evidence_room="room-other")
            with patch.object(verify, "ROOT", root), patch.object(verify, "OUTPUT", output), \
                 patch.object(verify.Settings, "from_env", return_value=self.settings()), patch.object(verify, "IMClient") as client:
                with self.assertRaisesRegex(ValueError, "another room"):
                    verify.main("product")
                client.assert_not_called()

    def test_misbound_reader_login_is_logged_out_without_business_or_model_work(self):
        calls = []

        class FakeClient:
            def __init__(self, base_url, token):
                self.token = token

            def request(self, method, path, body=None):
                calls.append((method, path, self.token))
                if path == "/admin/workers":
                    return {"workers": [{"principal": {"id": "agent-fixture"}, "token": "fixture-agent-secret"}]}
                if path == "/auth/login":
                    return {"principal": {"id": "wrong-reader"}, "token": "fixture-reader-secret"}
                if path == "/auth/logout":
                    return {"revoked": True}
                raise AssertionError("Unexpected business/network operation in an offline fixture")

        with tempfile.TemporaryDirectory() as folder:
            root, output = self.fixture(folder)
            with patch.object(verify, "ROOT", root), patch.object(verify, "OUTPUT", output), \
                 patch.object(verify.Settings, "from_env", return_value=self.settings()), patch.object(verify, "IMClient", FakeClient), \
                 patch.object(verify.OpenAICompatibleModel, "complete_json") as inference:
                with self.assertRaisesRegex(ValueError, "independent reader"):
                    verify.main("product")
                inference.assert_not_called()
            self.assertEqual([p for _, p, _ in calls], ["/admin/workers", "/auth/login", "/auth/logout"])
            self.assertEqual(calls[-1][2], "fixture-reader-secret")
            self.assertEqual(json.loads(output.read_text())["runs"][0]["error"]["class"], "ValueError")
            self.assertNotIn("fixture-reader-secret", output.read_text())


if __name__ == "__main__":
    unittest.main()

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("office_launcher", Path(__file__).resolve().parents[1] / "scripts" / "dev_office.py")
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class OfficeLauncherTest(unittest.TestCase):
    def test_restart_respects_members_removed_after_bootstrap(self):
        calls = []

        class Client:
            def __init__(self, base, token):
                pass

            def request(self, method, route, body=None):
                calls.append((method, route))
                if method != "GET" or route != "/me":
                    raise AssertionError("Restart must not alter established office membership")
                return {"principal": {"kind": "agent"}}

        with tempfile.TemporaryDirectory() as folder:
            access = {"bootstrap_complete": True, "room_id": "existing-room",
                **{name: {"token": "test-credential"} for name in ["human", "agent", "peer"]}}
            path = Path(folder) / "access.json"
            launcher.save_private(path, access)
            with patch.object(launcher, "IMClient", Client):
                self.assertEqual(launcher.provision("http://localhost", "test-admin", path), access)
            self.assertEqual(calls, [("GET", "/me")] * 3)
            self.assertEqual(json.loads(path.read_text()), access)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_local_accounts_are_private_and_never_reset_on_restart(self):
        accounts, creates = {}, []

        class Client:
            def __init__(self, base, token):
                self.token = token

            def request(self, method, route, body=None):
                if route == "/auth/account":
                    return {"account": accounts.get(self.token)}
                if route == "/admin/accounts" and self.token == "test-admin":
                    creates.append(dict(body))
                    accounts[body["principal_id"]] = {"username": body["username"]}
                    return {"account": accounts[body["principal_id"]]}
                raise AssertionError("Unexpected account operation")

        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "access.json"
            launcher.save_private(path, {name: {"token": name, "principal": {"id": name}}
                                         for name in ["human", "agent", "peer"]})
            with patch.object(launcher, "IMClient", Client):
                first = launcher.provision_local_accounts("http://localhost", "test-admin", path)
                accounts["human"] = {"username": "changed-by-user"}
                second = launcher.provision_local_accounts("http://localhost", "test-admin", path)
            self.assertEqual(len(creates), 3)
            self.assertEqual(first, second)
            self.assertEqual(len({entry["password"] for entry in creates}), 3)
            self.assertTrue(all(len(entry["password"]) >= 24 for entry in creates))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_enterprise_bootstrap_never_restores_a_changed_role(self):
        calls = []
        class Client:
            def __init__(self, base, token):
                pass
            def request(self, method, route, body=None):
                calls.append((method, route))
                if (method, route) != ("GET", "/enterprise"):
                    raise AssertionError("Existing enterprise must never be re-bootstrapped")
                return {"enterprise": {"initialized": True}, "membership": {"role": "member"}}
        with patch.object(launcher, "IMClient", Client):
            launcher.provision_local_enterprise("http://localhost", "test-admin", {
                "human": {"token": "human", "principal": {"id": "human"}}})
        self.assertEqual(calls, [("GET", "/enterprise")])


if __name__ == "__main__":
    unittest.main()

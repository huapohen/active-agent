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


if __name__ == "__main__":
    unittest.main()

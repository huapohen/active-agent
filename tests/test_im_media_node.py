"""SDK integration against an isolated copy of the actual Doc Free Node server.

No local environment/auth files or running office data are loaded. The sibling
doc_free checkout supplies code and installed Node dependencies only.
"""
import hashlib
import io
import os
from pathlib import Path
import secrets
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import unittest
import wave

from active_agent.im import IMClient, IMError


class NativeMediaNodeIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ.get("DOC_FREE_TEST_ROOT", Path(__file__).resolve().parents[2] / "doc_free"))
        node = shutil.which("node")
        if not node or not (source / "server.js").is_file() or not (source / "node_modules").is_dir():
            raise unittest.SkipTest("Doc Free checkout and installed Node dependencies are required")
        cls.temporary = tempfile.TemporaryDirectory(prefix="renji-sdk-node-media-")
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        stage = directory / "server"
        stage.mkdir()
        for item in source.iterdir():
            if item.is_file() and (item.suffix == ".js" or item.name in {"index.html", "native-emoji-catalog.json"}):
                shutil.copyfile(item, stage / item.name)
        (stage / "node_modules").symlink_to((source / "node_modules").resolve(), target_is_directory=True)
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            port = reserved.getsockname()[1]
        if port == 3218:
            raise RuntimeError("Integration must not use the live office port")
        cls.base = "http://127.0.0.1:%s" % port
        admin = secrets.token_urlsafe(32)
        environment = {
            "PATH": os.environ.get("PATH", ""), "HOST": "127.0.0.1", "PORT": str(port),
            "DOC_FREE_TOKEN": admin, "DOC_FREE_PUBLIC_URL": cls.base,
            "DOC_FREE_DATA": str(directory / "documents.json"),
            "DOC_FREE_IM_DATA": str(directory / "im.json"),
            "DOC_FREE_CRDT_DIR": str(directory / "crdt"),
        }
        cls.process = subprocess.Popen([node, "server.js"], cwd=stage, env=environment,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.addClassCleanup(cls.stop_process)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if cls.process.poll() is not None:
                raise RuntimeError("Isolated Doc Free server exited before readiness")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    break
            except OSError:
                time.sleep(.025)
        else:
            raise RuntimeError("Isolated Doc Free server readiness timed out")
        cls.admin = IMClient(cls.base, admin, timeout=5)

    @classmethod
    def stop_process(cls):
        if cls.process.poll() is None:
            cls.process.terminate()
            try:
                cls.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                cls.process.kill()
                cls.process.wait(timeout=3)

    def setUp(self):
        self.principals = []
        for label, kind in [("SDK Human", "human"), ("SDK Agent", "agent"), ("SDK Outsider", "human")]:
            result = self.admin.request("POST", "/admin/principals", {"name": label, "kind": kind})
            self.principals.append((IMClient(self.base, result["token"], timeout=5), result["principal"]))
        self.human, self.agent, self.outsider = [item[0] for item in self.principals]
        self.room = self.human.request("POST", "/rooms", {"name": "Isolated SDK media"})["room"]["id"]
        self.human.request("POST", "/rooms/" + self.room + "/members", {"principal_id": self.principals[1][1]["id"]})
        out = io.BytesIO()
        with wave.open(out, "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(b"".join(struct.pack("<h", (frame % 200 - 100) * 100) for frame in range(1600)))
        self.audio = out.getvalue()

    def assert_denied(self, operation, status, code):
        with self.assertRaises(IMError) as found:
            operation()
        self.assertEqual((found.exception.status, found.exception.code), (status, code))

    def test_real_http_human_upload_voice_download_and_outsider_denial(self):
        attachment = self.human.upload_attachment(self.room, self.audio, filename="voice.wav",
            client_id="stable-upload", mime_type="audio/wav")
        duplicate = self.human.upload_attachment(self.room, self.audio, filename="voice.wav",
            client_id="stable-upload", mime_type="audio/wav")
        self.assertEqual(duplicate["id"], attachment["id"])
        self.assertEqual(attachment["audio"]["duration_ms"], 100)
        self.assertEqual(attachment["mime_type"], "audio/wav")
        self.assertEqual(attachment["sha256"], hashlib.sha256(self.audio).hexdigest())
        sent = self.human.send_voice(self.room, attachment["id"], client_id="stable-message")
        self.assertEqual(sent["message"]["kind"], "voice")
        self.assertEqual(sent["message"]["voice"]["attachment_id"], attachment["id"])
        self.assertTrue(self.human.send_voice(self.room, attachment["id"], client_id="stable-message")["duplicate"])
        self.assertEqual(self.agent.download_attachment(self.room, attachment["id"]), self.audio)
        self.assert_denied(lambda: self.outsider.download_attachment(self.room, attachment["id"]), 403, "not_a_member")

    def test_real_http_agent_voice_hidden_recalled_and_invalid_audio_lifecycle(self):
        attachment = self.agent.upload_attachment(self.room, self.audio, filename="agent.wav",
            client_id="agent-upload", mime_type="audio/wav")
        message = self.agent.send_voice(self.room, attachment["id"], client_id="agent-message")["message"]
        self.assertEqual(message["voice"]["duration_ms"], 100)
        self.assertEqual(self.human.download_attachment(self.room, attachment["id"]), self.audio)
        route = "/rooms/" + self.room + "/messages/" + message["id"]
        self.human.request("PATCH", route + "/preferences", {"hidden": True})
        self.assert_denied(lambda: self.human.download_attachment(self.room, attachment["id"]), 409, "message_hidden")
        self.human.request("PATCH", route + "/preferences", {"hidden": False})
        self.agent.request("DELETE", route, {"base_revision": message["revision"]})
        self.assert_denied(lambda: self.human.download_attachment(self.room, attachment["id"]), 410, "attachment_recalled")
        self.assert_denied(lambda: self.agent.upload_attachment(self.room, b"fake WAV", filename="fake.wav",
            client_id="invalid-upload", mime_type="audio/wav"), 422, "invalid_voice_audio")


if __name__ == "__main__":
    unittest.main()

import importlib.util
from pathlib import Path
import unittest
import plistlib
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("office_release", Path(__file__).parents[1] / "scripts" / "office_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class ReleasePreflightTests(unittest.TestCase):
    def test_no_credentials_fails_closed_for_every_target(self):
        with patch.object(release, "capture", return_value=(-1, "", "")), patch.object(release.shutil, "which", return_value=None):
            for target in release.REQUIREMENTS:
                report = release.preflight(target, {})
                self.assertFalse(report["ready_for_attempt"])
                self.assertFalse(report["distribution_verified"])
                self.assertEqual(report["mode"], "read_only_preflight")

    def test_development_identity_is_never_accepted_as_developer_id(self):
        fingerprint = "A" * 40
        with patch.object(release.platform, "system", return_value="Darwin"), patch.object(release.shutil, "which", return_value="tool"), patch.object(release, "capture", return_value=(0, "", "")), patch.object(release, "apple_identities", return_value=[{"kind": "development", "sha1": fingerprint}]):
            report = release.preflight("macos", {"APPLE_SIGNING_IDENTITY_SHA1": fingerprint, "NOTARYTOOL_PROFILE": "fixture"})
            self.assertFalse(report["ready_for_attempt"])
            self.assertIn("configured production identity of type developer_id is unavailable", report["problems"])

    def test_android_secret_uses_env_reference_and_debug_cert_is_rejected(self):
        secret = "fixture-never-on-argv"
        env = {key: "fixture" for key in release.REQUIREMENTS["android"]}
        env["ANDROID_KEYSTORE_PASSWORD"] = secret
        output = "Owner: CN=Android Debug\nSHA256: " + ":".join(["AA"] * 32)
        with patch.object(release, "capture", return_value=(0, output, "")) as capture:
            self.assertIsNone(release.android_certificate(env))
            command = capture.call_args.args[0]
            self.assertNotIn(secret, command)
            self.assertIn("-storepass:env", command)

    def test_tool_error_never_forwards_provider_output(self):
        with patch.object(release, "capture", return_value=(1, "private-value", "private-value")):
            with self.assertRaises(RuntimeError) as error:
                release.execute(["fixture"], "fixture validation")
            self.assertNotIn("private-value", str(error.exception))

    def test_explicit_flutter_path_is_used_without_shell_interpretation(self):
        env = {"OFFICE_FLUTTER": str(Path("/isolated flutter/bin/flutter").resolve()), "PATH": "/isolated-tools"}
        with patch.object(release.shutil, "which", return_value=env["OFFICE_FLUTTER"]) as which, patch.object(release.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="ok", stderr="")) as run:
            self.assertEqual(release.capture(["flutter", "--version"], env=env), (0, "ok", ""))
            which.assert_called_once_with(env["OFFICE_FLUTTER"], path=env["PATH"])
            self.assertEqual(run.call_args.args[0], [env["OFFICE_FLUTTER"], "--version"])
            self.assertNotIn("shell", run.call_args.kwargs)

    def test_relative_flutter_override_does_not_fall_back_to_unintended_tool(self):
        with patch.object(release.shutil, "which") as which:
            self.assertIsNone(release.tool_path("flutter", {"OFFICE_FLUTTER": "relative/flutter"}))
            which.assert_not_called()

    def test_ios_non_dictionary_export_options_are_reported_without_crash(self):
        with tempfile.TemporaryDirectory() as directory:
            options = Path(directory) / "ExportOptions.plist"
            options.write_bytes(plistlib.dumps(["not a settings dictionary"]))
            env = {"APPLE_SIGNING_IDENTITY_SHA1": "A" * 40, "APPLE_TEAM_ID": "ABCDEFGHIJ", "IOS_EXPORT_OPTIONS_PLIST": str(options)}
            with patch.object(release.platform, "system", return_value="Darwin"), patch.object(release, "tool_path", return_value="tool"), patch.object(release, "apple_identities", return_value=[{"kind": "distribution", "sha1": "A" * 40}]):
                report = release.preflight("ios", env)
            self.assertFalse(report["ready_for_attempt"])
            self.assertIn("iOS export options are missing, invalid, or do not select the configured team/distribution method", report["problems"])

if __name__ == "__main__":
    unittest.main()

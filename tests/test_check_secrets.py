"""Run the actual index scanner against isolated staged fixtures."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class SecretScannerTests(unittest.TestCase):
    def scan_fixture(self, value):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy2(Path(__file__).parents[1] / "scripts/check_secrets.py", root / "scripts/check_secrets.py")
            (root / "fixture.txt").write_text(value, encoding="utf-8")
            subprocess.run(["git", "init", "--quiet"], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "add", "fixture.txt"], cwd=root, check=True, capture_output=True)
            return subprocess.run([sys.executable, "scripts/check_secrets.py"], cwd=root, capture_output=True, text=True)

    def test_real_key_prefix_is_rejected_without_echoing_value(self):
        value = "sk-" + "A" * 32
        result = self.scan_fixture(value)
        self.assertEqual(result.returncode, 1)
        self.assertIn("fixture.txt: credential-like content", result.stdout)
        self.assertNotIn(value, result.stdout + result.stderr)

    def test_task_uuid_is_not_mistaken_for_key_suffix(self):
        result = self.scan_fixture("task-12345678-1234-1234-1234-123456789012")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Secret scan: PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()

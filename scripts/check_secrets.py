#!/usr/bin/env python3
"""Fail closed on credential-like content and runtime files in the Git index."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
violations = []
for name in filter(None, files):
    path = Path(name)
    if ((path.name.startswith(".env") and not path.name.endswith(".example")) or
        path.parts[0] in {"data", "output", ".playwright-cli"} or
        path.suffix in {".db", ".pem", ".key"}):
        violations.append((name, "runtime or credential file"))
    result = subprocess.run(["git", "show", ":" + name], cwd=ROOT, capture_output=True)
    text = result.stdout.decode(errors="replace")
    if (re.search(r"(?<![A-Za-z0-9_])sk-[A-Za-z0-9_.-]{20,}", text) or
        re.search(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", text) or
        re.search(r"(?:postgres(?:ql)?|mysql)://[^\s:/]+:[^\s@]+@", text)):
        violations.append((name, "credential-like content"))
for name, reason in violations:
    print(name + ": " + reason)
print("Secret scan: %s (%s indexed paths)" % ("FAIL" if violations else "PASS", len(files) - 1))
sys.exit(bool(violations))

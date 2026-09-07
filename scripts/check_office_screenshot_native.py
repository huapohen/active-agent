#!/usr/bin/env python3
"""Compile and run screenshot parameter/output checks without capturing screens."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="renji-screenshot-native-") as folder:
    executable = pathlib.Path(folder) / "screenshot-checks"
    subprocess.run([
        "xcrun", "swiftc", "-o", str(executable),
        str(root / "apps/office/macos/Runner/OfficeScreenshotCapture.swift"),
        str(root / "apps/office/macos/RunnerTests/ScreenshotChecks/main.swift"),
    ], check=True)
    subprocess.run([str(executable)], check=True)

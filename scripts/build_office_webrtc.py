#!/usr/bin/env python3
"""Prepare the pinned Windows WebRTC binary with its upstream release digest.

The Flutter plugin's CMake build consumes this exact archive from its cache. Run
after flutter pub get and before flutter build windows; no credentials are needed.
"""
import hashlib
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VERSION = "1.6.1"
URL = ("https://github.com/webrtc-sdk/libwebrtc/releases/download/"
       "libwebrtc.m150.7871.00/libwebrtc-win-x64-release.zip")
SHA256 = "559dc6df08273aaf25b57e75a3c2e57adf3e8f40a93d55293bcffa36f64e139e"
SIZE = 8804772


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main():
    config = ROOT / "apps/office/.dart_tool/package_config.json"
    packages = json.loads(config.read_text())["packages"]
    entry = next(item for item in packages if item["name"] == "flutter_webrtc")
    uri = urllib.parse.urljoin(config.as_uri(), entry["rootUri"])
    parsed = urllib.parse.urlsplit(uri)
    if parsed.scheme != "file":
        raise RuntimeError("Expected the locally resolved flutter_webrtc package")
    package = Path(urllib.request.url2pathname(parsed.path))
    version = re.search(r"^version:\s*([^\s#]+)\s*(?:#.*)?$",
                        (package / "pubspec.yaml").read_text(), re.MULTILINE)
    if version is None or version.group(1).strip("\"'") != VERSION:
        raise RuntimeError("Update the pinned release digest when changing flutter_webrtc")
    destination = package / "third_party/downloads/libwebrtc-win-x64-release.zip"
    if destination.exists():
        if destination.stat().st_size != SIZE or digest(destination) != SHA256:
            raise RuntimeError("Cached Windows WebRTC archive failed integrity verification")
        print("Windows WebRTC archive: upstream SHA-256 verified (cached)")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".zip.part")
    size = 0
    with urllib.request.urlopen(URL, timeout=30) as response, temporary.open("wb") as output:
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            size += len(chunk)
            if size > SIZE:
                raise RuntimeError("Windows WebRTC archive exceeded the pinned size")
            output.write(chunk)
    if size != SIZE or digest(temporary) != SHA256:
        temporary.unlink()
        raise RuntimeError("Downloaded Windows WebRTC archive failed integrity verification")
    temporary.replace(destination)
    print("Windows WebRTC archive: upstream SHA-256 verified")


if __name__ == "__main__":
    main()

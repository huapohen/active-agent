#!/usr/bin/env python3
"""Configured production signing. Default: read-only preflight, never a preview fallback.

No certificate import, keychain unlock, signing, upload or build happens without
--execute. Secrets stay in the caller's environment or OS credential store.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OFFICE = ROOT / "apps" / "office"
REQUIREMENTS = {
    "macos": ["APPLE_SIGNING_IDENTITY_SHA1", "NOTARYTOOL_PROFILE"],
    "ios": ["APPLE_SIGNING_IDENTITY_SHA1", "APPLE_TEAM_ID", "IOS_EXPORT_OPTIONS_PLIST"],
    "android": ["ANDROID_KEYSTORE_PATH", "ANDROID_KEY_ALIAS", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_PASSWORD", "ANDROID_CERT_SHA256"],
    "windows": ["WINDOWS_CERT_SHA1", "WINDOWS_TIMESTAMP_URL"],
}

def tool_path(name, env=None):
    """Resolve the actual executable using the same environment as the child."""
    env = os.environ if env is None else env
    if name == "flutter" and env.get("OFFICE_FLUTTER"):
        candidate = Path(env["OFFICE_FLUTTER"]).expanduser()
        if not candidate.is_absolute():
            return None
        name = str(candidate)
    return shutil.which(name, path=env.get("PATH", os.defpath))

def capture(command, *, env=None, cwd=OFFICE, timeout=30):
    """Never forward tool output: tools can print certificate subjects or secrets."""
    try:
        executable = tool_path(command[0], env)
        if not executable:
            return -1, "", ""
        result = subprocess.run([executable, *command[1:]], cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout, check=False)
        return result.returncode, result.stdout, result.stderr
    except (OSError, subprocess.TimeoutExpired):
        return -1, "", ""

def execute(command, label, *, env=None, cwd=OFFICE, timeout=3600):
    print(json.dumps({"step": label, "status": "running"}), flush=True)
    code, output, _ = capture(command, env=env, cwd=cwd, timeout=timeout)
    if code:
        raise RuntimeError(f"{label} failed; tool output suppressed to avoid leaking credentials")
    return output

def fingerprint(value, length):
    return bool(re.fullmatch(r"[A-Fa-f0-9]{" + str(length) + r"}", value or ""))

def apple_identities(env=None):
    code, output, _ = capture(["security", "find-identity", "-v", "-p", "codesigning"], env=env)
    if code:
        return []
    result = []
    for digest, label in re.findall(r'\b([A-F0-9]{40})\b.*?"([^"\n]+)"', output):
        kind = "developer_id" if label.startswith("Developer ID Application:") else "distribution" if label.startswith(("Apple Distribution:", "iPhone Distribution:")) else "development" if label.startswith(("Apple Development:", "iPhone Developer:")) else "other"
        result.append({"kind": kind, "sha1": digest})
    return result

def android_certificate(env):
    if not all(env.get(name) for name in REQUIREMENTS["android"]):
        return None
    code, output, _ = capture(["keytool", "-J-Duser.language=en", "-list", "-v", "-keystore", env["ANDROID_KEYSTORE_PATH"], "-alias", env["ANDROID_KEY_ALIAS"], "-storepass:env", "ANDROID_KEYSTORE_PASSWORD"], env=env)
    match = re.search(r"SHA256:\s*([A-Fa-f0-9:]{64,95})", output)
    if code or not match or "CN=Android Debug" in output:
        return None
    return match.group(1).replace(":", "").upper()

def windows_certificate(env):
    if not fingerprint(env.get("WINDOWS_CERT_SHA1"), 40):
        return None
    location = env.get("WINDOWS_CERT_STORE_LOCATION", "CurrentUser")
    if location not in ("CurrentUser", "LocalMachine"):
        return None
    # Script is fixed; user values are read from env, never interpolated as code.
    ps = "$location = $env:WINDOWS_CERT_STORE_LOCATION; if (!$location) {$location = 'CurrentUser'}; $c = @(Get-ChildItem ('Cert:\\' + $location + '\\My') | Where-Object {$_.Thumbprint -eq $env:WINDOWS_CERT_SHA1 -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.3'}); @{count=$c.Count; fingerprints=@($c | ForEach-Object {$_.Thumbprint})} | ConvertTo-Json -Compress"
    code, output, _ = capture(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], env=env)
    try:
        result = json.loads(output)
        return result if code == 0 and result.get("count") == 1 else None
    except ValueError:
        return None

def preflight(target, env=None):
    env = dict(os.environ if env is None else env)
    configured = {name: bool(env.get(name)) for name in REQUIREMENTS[target]}
    problems = ["missing " + name for name, present in configured.items() if not present]
    result = {"target": target, "mode": "read_only_preflight", "configured": configured, "problems": problems}
    result["flutter_override_configured"] = bool(env.get("OFFICE_FLUTTER"))
    if not tool_path("flutter", env):
        problems.append("Flutter is unavailable; set OFFICE_FLUTTER to an executable absolute path or add Flutter to PATH")
    if target in ("macos", "ios"):
        if platform.system() != "Darwin":
            problems.append("requires a macOS signing host")
        identities = apple_identities(env) if platform.system() == "Darwin" else []
        result["identities"] = identities
        result["identity_count"] = len(identities)
        wanted = env.get("APPLE_SIGNING_IDENTITY_SHA1", "").upper()
        kind = "developer_id" if target == "macos" else "distribution"
        if not fingerprint(wanted, 40) or not any(i["sha1"] == wanted and i["kind"] == kind for i in identities):
            problems.append("configured production identity of type " + kind + " is unavailable")
        if target == "macos":
            result["notarytool_installed"] = capture(["xcrun", "--find", "notarytool"], env=env)[0] == 0
            if not result["notarytool_installed"]:
                problems.append("notarytool is unavailable")
            result["notary_profile_validation"] = "not contacted; stored profile presence is not established by this preflight"
        else:
            if not re.fullmatch(r"[A-Z0-9]{10}", env.get("APPLE_TEAM_ID", "")):
                problems.append("APPLE_TEAM_ID must be a 10-character team identifier")
            try:
                options_path = Path(env.get("IOS_EXPORT_OPTIONS_PLIST", ""))
                if not options_path.is_absolute():
                    raise ValueError()
                export = plistlib.loads(options_path.read_bytes())
                if not isinstance(export, dict) or export.get("teamID") != env.get("APPLE_TEAM_ID") or export.get("method") not in ("app-store-connect", "release-testing", "enterprise", "app-store", "ad-hoc"):
                    raise ValueError()
            except (OSError, ValueError, plistlib.InvalidFileException):
                problems.append("iOS export options are missing, invalid, or do not select the configured team/distribution method")
            result["provisioning_validation"] = "Runner archive signing and valid installed distribution profiles must also be configured in Xcode"
    elif target == "android":
        keystore = Path(env.get("ANDROID_KEYSTORE_PATH", ""))
        if not keystore.is_absolute() or not keystore.is_file():
            problems.append("release keystore must be an available absolute file path")
        found = android_certificate(env)
        result["certificate_sha256"] = found
        expected = env.get("ANDROID_CERT_SHA256", "").upper()
        if not fingerprint(expected, 64) or not found or found != expected:
            problems.append("keystore certificate does not match ANDROID_CERT_SHA256, cannot be read, or is a debug certificate")
        if not tool_path("jarsigner", env):
            problems.append("jarsigner is not on PATH")
    elif target == "windows":
        if platform.system() != "Windows":
            problems.append("requires a Windows signing host")
        if not tool_path("signtool", env):
            problems.append("Windows SDK signtool is not on PATH")
        if not re.fullmatch(r"https://[^\s/@]+(?:/[^\s]*)?", env.get("WINDOWS_TIMESTAMP_URL", "")):
            problems.append("WINDOWS_TIMESTAMP_URL must be a configured HTTPS timestamp service")
        result["certificate"] = windows_certificate(env) if platform.system() == "Windows" else None
        if not result["certificate"]:
            problems.append("exact unexpired code-signing certificate with private key was not found in configured Windows store")
    result["ready_for_attempt"] = not problems
    result["distribution_verified"] = False
    return result

def sign_macos(destination, env):
    execute(["flutter", "build", "macos", "--release"], "build macOS release", env=env)
    source = OFFICE / "build/macos/Build/Products/Release/Active Office.app"
    app = destination / source.name
    shutil.copytree(source, app, symlinks=True)
    identity = env["APPLE_SIGNING_IDENTITY_SHA1"]
    bundles = [p for p in app.rglob("*") if not p.is_symlink() and (p.suffix in (".framework", ".app", ".xpc", ".appex", ".dylib"))]
    for nested in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        execute(["codesign", "--force", "--timestamp", "--options", "runtime", "--sign", identity, str(nested)], "sign embedded macOS code")
    execute(["codesign", "--force", "--timestamp", "--options", "runtime", "--entitlements", str(OFFICE / "macos/Runner/Release.entitlements"), "--sign", identity, str(app)], "sign macOS application")
    execute(["codesign", "--verify", "--deep", "--strict", str(app)], "verify macOS code signatures")
    archive = destination / "active-office-macos-notarized.zip"
    execute(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], "package notarization upload")
    result = execute(["xcrun", "notarytool", "submit", str(archive), "--keychain-profile", env["NOTARYTOOL_PROFILE"], "--wait", "--output-format", "json"], "submit Apple notarization", timeout=1800)
    if json.loads(result).get("status") != "Accepted":
        raise RuntimeError("Apple notarization did not return Accepted")
    execute(["xcrun", "stapler", "staple", str(app)], "staple notarization ticket")
    execute(["xcrun", "stapler", "validate", str(app)], "validate stapled notarization ticket")
    execute(["spctl", "--assess", "--type", "execute", str(app)], "verify Gatekeeper assessment")
    archive.unlink()
    execute(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], "package stapled macOS application")
    return [archive], {"signature": "Developer ID", "notarization": "Accepted and stapled"}

def sign_ios(destination, env):
    # Runner target archive signing is configured in Xcode. ExportOptions selects
    # the team's actual distribution provisioning; no --no-codesign fallback.
    execute(["flutter", "build", "ipa", "--release", "--export-options-plist", str(Path(env["IOS_EXPORT_OPTIONS_PLIST"]).resolve())], "build and export signed iOS archive", env=env)
    ipas = list((OFFICE / "build/ios/ipa").glob("*.ipa"))
    if len(ipas) != 1:
        raise RuntimeError("expected exactly one exported IPA")
    archive = destination / "active-office-ios-signed.ipa"
    shutil.copy2(ipas[0], archive)
    with tempfile.TemporaryDirectory(prefix="office-ipa-verify-") as directory:
        with zipfile.ZipFile(archive) as bundle:
            for entry in bundle.infolist():
                if entry.filename.startswith("/") or ".." in Path(entry.filename).parts:
                    raise RuntimeError("unexpected IPA path")
            bundle.extractall(directory)
        apps = list((Path(directory) / "Payload").glob("*.app"))
        if len(apps) != 1 or not (apps[0] / "embedded.mobileprovision").is_file():
            raise RuntimeError("IPA has no unique provisioned application")
        execute(["codesign", "--verify", "--deep", "--strict", str(apps[0])], "verify exported iOS application")
        details = execute(["codesign", "--display", "--entitlements", "-", str(apps[0])], "read exported iOS entitlements")
        entitlements = plistlib.loads(details.encode())
        if entitlements.get("get-task-allow") or entitlements.get("com.apple.developer.team-identifier") != env["APPLE_TEAM_ID"]:
            raise RuntimeError("IPA is development-signed or belongs to another team")
        prefix = str(Path(directory) / "certificate")
        execute(["codesign", "--display", "--extract-certificates", prefix, str(apps[0])], "inspect exported iOS signing certificate")
        if hashlib.sha1(Path(prefix + "0").read_bytes()).hexdigest().upper() != env["APPLE_SIGNING_IDENTITY_SHA1"].upper():
            raise RuntimeError("IPA signer differs from the configured distribution certificate")
    return [archive], {"signature": "Apple distribution with matching team and certificate", "store_submission": "not submitted"}

def sign_android(destination, env):
    build_env = {**env, "OFFICE_ANDROID_PRODUCTION_SIGNING": "1"}
    execute(["flutter", "build", "appbundle", "--release"], "build signed Android App Bundle", env=build_env)
    source = OFFICE / "build/app/outputs/bundle/release/app-release.aab"
    archive = destination / "active-office-android-signed.aab"
    shutil.copy2(source, archive)
    execute(["jarsigner", "-verify", str(archive)], "verify Android bundle signature", env=env)
    details = execute(["keytool", "-J-Duser.language=en", "-printcert", "-jarfile", str(archive)], "inspect Android bundle signer", env=env)
    found = re.search(r"SHA256:\s*([A-Fa-f0-9:]{64,95})", details)
    if not found or found.group(1).replace(":", "").upper() != env["ANDROID_CERT_SHA256"].upper():
        raise RuntimeError("Android bundle signer differs from the configured production certificate")
    return [archive], {"signature": "matching release keystore certificate", "store_submission": "not submitted"}

def sign_windows(destination, env):
    execute([sys.executable, str(ROOT / "scripts/build_office_webrtc.py")], "prepare Windows WebRTC dependency", env=env)
    execute(["flutter", "build", "windows", "--release"], "build Windows release", env=env)
    target = destination / "active-office-windows"
    shutil.copytree(OFFICE / "build/windows/x64/runner/Release", target)
    binaries = sorted([*target.rglob("*.exe"), *target.rglob("*.dll")])
    if not binaries:
        raise RuntimeError("Windows release contains no signable code")
    for binary in binaries:
        command = ["signtool", "sign", "/sha1", env["WINDOWS_CERT_SHA1"], "/fd", "SHA256", "/tr", env["WINDOWS_TIMESTAMP_URL"], "/td", "SHA256"]
        if env.get("WINDOWS_CERT_STORE_LOCATION") == "LocalMachine":
            command.append("/sm")
        execute([*command, str(binary)], "sign Windows code with timestamp", env=env)
        execute(["signtool", "verify", "/pa", "/all", str(binary)], "verify Windows Authenticode", env=env)
    archive = Path(shutil.make_archive(str(destination / "active-office-windows-signed"), "zip", target))
    return [archive], {"signature": "Authenticode with SHA-256 timestamp", "binary_count": len(binaries)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=REQUIREMENTS)
    parser.add_argument("--execute", action="store_true", help="build, sign and (macOS only) upload to Apple notarization after preflight")
    args = parser.parse_args()
    env = dict(os.environ)
    report = preflight(args.target, env)
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
    if not report["ready_for_attempt"]:
        return 2
    if not args.execute:
        return 0
    code, commit, _ = capture(["git", "rev-parse", "HEAD"], cwd=ROOT)
    dirty = capture(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT)
    if code or dirty[0] or dirty[1].strip():
        raise RuntimeError("production signing requires a clean committed source checkout")
    destination = ROOT / "output" / "production" / commit.strip() / args.target
    destination.mkdir(parents=True, exist_ok=False)
    artifacts, verification = {"macos": sign_macos, "ios": sign_ios, "android": sign_android, "windows": sign_windows}[args.target](destination, env)
    manifest = {"commit": commit.strip(), "built_at_utc": datetime.now(timezone.utc).isoformat(), "target": args.target,
                "verification": verification, "artifacts": [{"file": p.name, "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in artifacts]}
    (destination / "PRODUCTION-MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "verified", "manifest": str(destination / "PRODUCTION-MANIFEST.json")}), flush=True)
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError) as error:
        # These messages are constructed locally; provider/tool payloads are never included.
        message = str(error) if isinstance(error, RuntimeError) else "Release operation failed; inspect configured paths and tools without exposing credentials"
        print(json.dumps({"status": "failed", "error": message}), file=sys.stderr)
        sys.exit(1)

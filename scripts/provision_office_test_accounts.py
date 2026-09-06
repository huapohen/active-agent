#!/usr/bin/env python3
"""Create and verify three local test identities without resetting existing users.

Credentials are read from ignored local files and only saved to a mode-0600
manifest. The owner manages members; the bootstrap token only enrolls passwords.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from active_agent.im import IMClient, IMError
from dev_office import save_private

SCHEMA = "native-office-test-accounts-v1"
TARGETS = (
    ("test.admin", "测试·企业管理员", "human", "admin"),
    ("test.employee", "测试·普通员工", "human", "member"),
    ("test.agent", "测试·Agent 同事", "agent", "member"),
)


def require(condition, code):
    if not condition:
        raise ValueError(code)


def read_private(path):
    require(path.stat().st_mode & 0o077 == 0, "private_file_permissions")
    return json.loads(path.read_text())


def require_ignored(path):
    check = subprocess.run(["git", "check-ignore", "--quiet", "--", str(path)],
                           cwd=ROOT, capture_output=True)
    require(check.returncode == 0, "credential_manifest_must_be_git_ignored")


def provision(base_url, data, evidence_path):
    parsed = urlsplit(base_url)
    require(parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}
            and not parsed.username and not parsed.password and not parsed.query
            and not parsed.fragment and parsed.path in {"", "/"}, "loopback_development_only")
    manifest_path = data / "test-accounts.json"
    require_ignored(manifest_path)
    access = read_private(data / "access.json")
    demo = read_private(data / "demo-company.json")
    require(demo.get("base_url") == base_url and demo.get("schema") == "native-company-demo-v1",
            "wrong_demo_service")
    owner = IMClient(base_url, access["human"]["token"])
    bootstrap = IMClient(base_url, read_private(data / "admin.json")["token"])
    public = IMClient(base_url, "public-login")
    owner_id = access["human"]["principal"]["id"]
    require(owner.request("GET", "/me")["principal"]["id"] == owner_id, "owner_identity_mismatch")
    require(owner.request("GET", "/enterprise")["membership"]["role"] == "owner", "owner_role_required")
    owner_sessions = owner.request("GET", "/auth/sessions")["sessions"]
    password = access["human"]["account"]["password"]
    require(isinstance(password, str) and len(password) >= 6, "local_password_missing")
    manifest = read_private(manifest_path) if manifest_path.exists() else {
        "schema": SCHEMA, "base_url": base_url, "owner_id": owner_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "organization_id": demo["organization"]["id"], "room_id": demo["room_id"], "accounts": {},
    }
    require(manifest.get("schema") == SCHEMA and manifest.get("base_url") == base_url
            and manifest.get("owner_id") == owner_id and manifest.get("organization_id") == demo["organization"]["id"]
            and manifest.get("room_id") == demo["room_id"], "manifest_identity_mismatch")
    save = lambda: save_private(manifest_path, manifest)
    save()

    def close_session(entry):
        session = entry.get("verification_session")
        if not session:
            return
        require(session["principal_id"] != owner_id, "refuse_to_logout_owner_session")
        client = IMClient(base_url, session["token"])
        try:
            require(client.request("GET", "/me")["principal"]["id"] == session["principal_id"],
                    "session_identity_mismatch")
            client.request("POST", "/auth/logout", {})
        except IMError as exc:
            if exc.status != 401:
                raise
        try:
            client.request("GET", "/me")
        except IMError as exc:
            require(exc.status == 401, "session_logout_not_verified")
        else:
            raise ValueError("session_still_active")
        del entry["verification_session"]
        save()

    def login(entry):
        result = public.request("POST", "/auth/login", entry["account"])
        entry["verification_session"] = {"token": result["token"], "session_id": result["session_id"],
                                          "principal_id": result["principal"]["id"]}
        save()
        return result, IMClient(base_url, result["token"])

    room_route = "/rooms/" + demo["room_id"]
    for username, name, kind, role in TARGETS:
        entry = manifest["accounts"].setdefault(username, {
            "name": name, "kind": kind, "role": role,
            "client_id": SCHEMA + ":" + username,
            "account": {"username": username, "password": password},
        })
        require(entry.get("kind") == kind and entry.get("role") == role and entry.get("name") == name
                and entry.get("account", {}).get("username") == username
                and entry.get("client_id") == SCHEMA + ":" + username, "account_intent_mismatch")
        save()  # Persist account intent before any member or password mutation.
        close_session(entry)
        if "principal_id" not in entry:
            try:
                login(entry)
            except IMError as exc:
                # The server's public login failure deliberately uses a generic
                # 401. Older IMClient versions do not expose its top-level code.
                if exc.status != 401:
                    raise
            else:
                close_session(entry)
                raise ValueError("existing_username_not_owned_by_manifest")
            result = owner.request("POST", "/enterprise/admin/members", {
                "name": name, "kind": kind, "organization_id": manifest["organization_id"],
                "profession": "本机权限与协作验收", "job_title": "测试管理员" if role == "admin" else "测试同事",
                "client_id": entry["client_id"],
            })
            entry["principal_id"] = result["member"]["id"]
            if result.get("token"):
                entry["machine_token"] = result["token"]
            save()
        member_route = "/enterprise/admin/members/" + entry["principal_id"]
        member = owner.request("GET", member_route)["member"]
        require(member["kind"] == kind and member["name"] == name
                and member["organization_id"] == manifest["organization_id"]
                and member["status"] == "active" and member["role"] in {"member", role}, "member_identity_mismatch")
        if entry.get("machine_token"):
            own = IMClient(base_url, entry["machine_token"])
            require(own.request("GET", "/me")["principal"]["id"] == entry["principal_id"], "machine_identity_mismatch")
            account = own.request("GET", "/auth/account")["account"]
            if account is None:
                # This endpoint resets enrolled accounts, so it is called only
                # after the target's own credential proves there is no account.
                bootstrap.request("POST", "/admin/accounts", {
                    "principal_id": entry["principal_id"], **entry["account"],
                })
            else:
                require(account["username"] == username, "existing_account_conflict")
        result, client = login(entry)
        try:
            require(result["principal"]["id"] == entry["principal_id"], "username_collision")
            require(client.request("GET", "/auth/account")["account"]["username"] == username,
                    "account_username_mismatch")
            entry["account_initialized"] = True
            save()
        finally:
            close_session(entry)
        if member["role"] != role:
            owner.request("PATCH", member_route, {"base_revision": member["revision"], "role": role})
        detail = owner.request("GET", room_route)
        if not any(m["principal_id"] == entry["principal_id"] for m in detail["members"]):
            owner.request("POST", room_route + "/members", {"principal_id": entry["principal_id"]})
        if kind == "agent":
            detail = owner.request("GET", room_route)
            membership = next(m for m in detail["members"] if m["principal_id"] == entry["principal_id"])
            if membership.get("mode") != "paused":
                owner.request("PATCH", room_route + "/participation", {
                    "principal_id": entry["principal_id"], "mode": "paused"})
        entry["provisioned"] = True
        save()

    documents = owner.request("GET", room_route)["documents"]
    require(len(documents) > 0, "shared_documents_missing")
    expected_documents = {d["id"]: owner.request("GET", room_route + "/documents/" + d["id"])["document"]
                          for d in documents}
    checks = []
    active_sessions = set()
    try:
        # Keep all three test sessions alive concurrently; no simulator needed.
        clients = []
        for username, _, kind, role in TARGETS:
            entry = manifest["accounts"][username]
            result, client = login(entry)
            require(result["principal"]["id"] == entry["principal_id"] and result["principal"]["kind"] == kind,
                    "login_identity_mismatch")
            require(result["session_id"] not in active_sessions, "sessions_not_independent")
            active_sessions.add(result["session_id"])
            clients.append((username, entry, client))
        for username, entry, client in clients:
            membership = client.request("GET", "/enterprise")["membership"]
            require(membership["role"] == entry["role"] and membership["organization_id"] == manifest["organization_id"],
                    "enterprise_membership_mismatch")
            try:
                client.request("GET", "/enterprise/admin/members?limit=1")
            except IMError as exc:
                require(entry["role"] == "member" and exc.status == 403, "unexpected_management_denial")
                management_status = 403
            else:
                require(entry["role"] == "admin", "member_management_privilege_leak")
                management_status = 200
            detail = client.request("GET", room_route)
            ids = {m["principal_id"] for m in detail["members"]}
            require(all(e["principal_id"] in ids for e in manifest["accounts"].values()), "shared_room_membership_missing")
            for did, expected in expected_documents.items():
                actual = client.request("GET", room_route + "/documents/" + did)["document"]
                for field in ("id", "revision", "content", "content_hash"):
                    require(actual.get(field) == expected.get(field), "shared_document_mismatch")
            checks.append({"username": username, "kind": entry["kind"], "role": entry["role"],
                           "login": "passed", "management_http_status": management_status,
                           "shared_room": "passed", "shared_documents_verified": len(expected_documents)})
    finally:
        cleanup_errors = []
        for entry in manifest["accounts"].values():
            try:
                close_session(entry)
            except (IMError, ValueError, OSError, KeyError) as exc:
                cleanup_errors.append(exc)
        if cleanup_errors:
            raise cleanup_errors[0]
    require(owner.request("GET", "/enterprise")["membership"]["role"] == "owner", "owner_role_changed")
    after_sessions = {session["id"]: session for session in owner.request("GET", "/auth/sessions")["sessions"]}
    # Other UI clients may legitimately sign in while this runs. Preserve every
    # pre-existing session; do not require the entire session list to be frozen.
    for session in owner_sessions:
        before = {key: value for key, value in session.items() if key != "active"}
        after = {key: value for key, value in after_sessions.get(session["id"], {}).items() if key != "active"}
        require(before == after, "owner_sessions_changed")
    summary = {"schema": SCHEMA + ":verification", "verified_at": datetime.now(timezone.utc).isoformat(),
               "base_url": base_url, "organization": demo["organization"]["name"], "room_id": demo["room_id"],
               "checks": checks, "simultaneous_independent_sessions": len(active_sessions),
               "test_sessions_logged_out": True, "owner_role_and_sessions_preserved": True,
               "test_agent_room_mode": "paused", "private_manifest_mode": oct(manifest_path.stat().st_mode & 0o777),
               "password_length": len(password), "password_sha256_short": hashlib.sha256(password.encode()).hexdigest()[:12],
               "documents": [{"id": did, "revision": d.get("revision")} for did, d in expected_documents.items()],
               "no_chat_or_model_calls": True}
    manifest["last_verification"] = summary
    save()
    if evidence_path:
        evidence_path.parent.mkdir(parents=True, exist_ok=True)
        evidence_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:3218")
    parser.add_argument("--data", type=Path, default=ROOT / "data" / "office")
    parser.add_argument("--evidence", type=Path, default=ROOT / "output" / "test-accounts-verification.json")
    args = parser.parse_args()
    provision(args.base_url.rstrip("/"), args.data.resolve(), args.evidence.resolve())


if __name__ == "__main__":
    try:
        main()
    except (IMError, ValueError, OSError, KeyError) as exc:
        # Local credentials and arbitrary backend response text never reach logs.
        print("Test account setup stopped: " + (exc.code if isinstance(exc, IMError) else type(exc).__name__), file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Start a local native office IM with isolated state and individual identities."""
import argparse
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from active_agent.config import Settings
from active_agent.im import IMClient, IMError


def save_private(path, value):
    temporary = path.with_suffix(".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def provision(base_url, admin_token, path):
    access = json.loads(path.read_text()) if path.exists() else {}
    admin = IMClient(base_url, admin_token)
    for name, kind, label in [("human", "human", "huapohen"),
                              ("agent", "agent", "Active Agent"),
                              ("peer", "human", "本机协作成员")]:
        if name in access:
            # Revocation or mismatched state must not silently create a replacement identity.
            IMClient(base_url, access[name]["token"]).request("GET", "/me")
            continue
        access[name] = admin.request("POST", "/admin/principals", {"name": label, "kind": kind})
        save_private(path, access)
    if access.get("bootstrap_complete"):
        return access
    human = IMClient(base_url, access["human"]["token"])
    if "room_id" not in access:
        room = human.request("POST", "/rooms", {"name": "原生办公 · 产品共创",
            "description": "围绕同一份文档讨论、分工、交付。人和 Agent 都是团队成员。"})["room"]
        access["room_id"] = room["id"]
        save_private(path, access)
    room_id = access["room_id"]
    detail = human.request("GET", "/rooms/" + room_id)
    if not detail["documents"]:
        human.request("POST", "/rooms/" + room_id + "/documents", {
            "title": "原生办公 · 团队工作约定",
            "content": "# 团队目标\n\n把 Active Agent 与 Doc Free 连接成办公协作软件，让人和 Agent 在共同的会话、任务与文档中推进工作。\n\n"
                "## 工作方式\n\n- 在会话里明确需求与约束。\n- 把行动项建成任务，负责人可以是人或 Agent。\n"
                "- 文档是共同依据；修改保留版本。\n- Agent 的输入依据、结果与阻塞原因对成员可见。\n"
                "- 产出先作为草稿审阅，再保存为共享文档。\n\n## 本机演示边界\n\n这是本机开发工作区；示例内容不代表已完成企业生产验收。\n"})
    existing = {m["principal_id"] for m in detail["members"]}
    for name in ["agent", "peer"]:
        principal_id = access[name]["principal"]["id"]
        if principal_id not in existing:
            human.request("POST", "/rooms/" + room_id + "/members", {"principal_id": principal_id})
    access["bootstrap_complete"] = True
    save_private(path, access)
    return access


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_repo = ROOT.parent / "doc_free"
    if not default_repo.exists():
        default_repo = ROOT.parent / "doc-free"
    parser.add_argument("--doc-free", type=Path, default=default_repo)
    parser.add_argument("--port", type=int, default=3218)
    parser.add_argument("--collab-port", type=int, default=1238)
    parser.add_argument("--no-worker", action="store_true")
    args = parser.parse_args()
    repository = args.doc_free.resolve()
    if not (repository / "native-im.js").exists():
        parser.error("--doc-free must point to a Doc Free checkout on equal_rights")
    if not (repository / "node_modules").exists():
        parser.error("Run npm ci in the Doc Free checkout first")
    for port in [args.port, args.collab_port]:
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("127.0.0.1", port))
            except OSError:
                parser.error("Port %s is already in use; choose a different local port" % port)
    os.chdir(ROOT)
    settings = Settings.from_env()
    data = ROOT / "data" / "office"
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    admin_path = data / "admin.json"
    if not admin_path.exists():
        save_private(admin_path, {"token": secrets.token_hex(32)})
    admin_token = json.loads(admin_path.read_text())["token"]
    base_url = "http://127.0.0.1:%s" % args.port
    environment = {**os.environ, "DOC_FREE_TOKEN": admin_token, "PORT": str(args.port),
        "COLLAB_PORT": str(args.collab_port), "COLLAB_HOST": "127.0.0.1",
        "COLLAB_URL": "http://127.0.0.1:%s" % args.collab_port,
        "DOC_FREE_DATA": str(data / "documents.json"), "DOC_FREE_CRDT_DIR": str(data / "crdt"),
        "DOC_FREE_OFFICE_BUILD": str(ROOT / "apps" / "office" / "build" / "web"),
        "DOC_FREE_IM_DATA": str(data / "native-im.json"), "HOST": "127.0.0.1"}
    node_environment = {k: v for k, v in environment.items() if not k.startswith("AA_")}
    subprocess.run(["npm", "run", "build"], cwd=repository, env=node_environment, check=True)
    processes = []

    def terminate(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    try:
        for file in ["collab-server.js", "server.js"]:
            processes.append(subprocess.Popen(["node", file], cwd=repository, env=node_environment))
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for _ in range(80):
            if any(p.poll() is not None for p in processes):
                raise RuntimeError("An office service exited during startup")
            try:
                with opener.open(base_url + "/health", timeout=1):
                    break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError("Office server did not become ready")
        access = provision(base_url, admin_token, data / "access.json")
        if not args.no_worker:
            worker_environment = {**os.environ, "AA_DOC_FREE_URL": base_url,
                "AA_IM_TOKEN": access["agent"]["token"], "AA_IM_ADMIN_TOKEN": admin_token}
            # The native participant never receives the administrative workspace credential.
            worker_environment["AA_DOC_FREE_TOKEN"] = ""
            processes.append(subprocess.Popen([sys.executable, "-m", "active_agent.cli", "im-fleet"],
                cwd=ROOT, env=worker_environment))
        print("Office: %s/office/ (Flutter); %s/im (HTML preview)" % (base_url, base_url), flush=True)
        print("Individual local access: data/office/access.json (private, mode 0600).", flush=True)
        print("Use human.token to sign in; agent runs independently. Ctrl-C stops services.", flush=True)
        while all(p.poll() is None for p in processes):
            time.sleep(1)
        raise RuntimeError("An office service exited; all companion services stopped")
    except KeyboardInterrupt:
        pass
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
        for process in processes:
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, IMError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Run a private local collaboration workspace without touching Doc Free's old data."""
import argparse
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from active_agent.config import Settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--doc-free", type=Path, default=ROOT.parent / "doc-free")
    parser.add_argument("--port", type=int, default=3217)
    parser.add_argument("--collab-port", type=int, default=1237)
    parser.add_argument("--no-worker", action="store_true")
    args = parser.parse_args()
    repository = args.doc_free.resolve()
    if not (repository / "workspace.js").exists():
        parser.error("--doc-free must point to a Doc Free checkout on the evolve branch")
    if not (repository / "node_modules").exists():
        parser.error("Run npm ci in the Doc Free checkout first")
    os.chdir(ROOT)
    settings = Settings.from_env()
    token = settings.doc_free_token
    if not token:
        token = secrets.token_hex(24)
        local = ROOT / ".env"
        lines = local.read_text().splitlines() if local.exists() else []
        lines = [line for line in lines if not line.startswith("AA_DOC_FREE_TOKEN=")]
        lines.append("AA_DOC_FREE_TOKEN=" + token)
        local.write_text("\n".join(lines) + "\n"); local.chmod(0o600)
    data = ROOT / "data" / "workspace"
    data.mkdir(parents=True, exist_ok=True)
    environment = {**os.environ, "DOC_FREE_TOKEN": token, "PORT": str(args.port),
        "COLLAB_PORT": str(args.collab_port), "COLLAB_URL": "http://127.0.0.1:%s" % args.collab_port,
        "DOC_FREE_DATA": str(data / "data.json"), "DOC_FREE_CRDT_DIR": str(data / "crdt"),
        "AA_DOC_FREE_URL": "http://127.0.0.1:%s" % args.port, "AA_DOC_FREE_TOKEN": token,
        "AA_DB_PATH": str(data / "worker.db"), "HOST": "127.0.0.1"}
    node_environment = {k: v for k, v in environment.items() if not k.startswith("AA_MODEL_")}
    subprocess.run(["npm", "run", "build"], cwd=repository, env=node_environment, check=True)
    processes = []
    def terminate(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    try:
        for file in ["collab-server.js", "server.js"]:
            processes.append(subprocess.Popen(["node", file], cwd=repository, env=node_environment))
        for _ in range(60):
            if any(p.poll() is not None for p in processes):
                raise RuntimeError("A workspace service exited during startup")
            try:
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open(environment["AA_DOC_FREE_URL"] + "/health", timeout=1):
                    break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError("Workspace did not become ready")
        if not args.no_worker:
            processes.append(subprocess.Popen([sys.executable, "-m", "active_agent.cli", "documents"], cwd=ROOT, env=environment))
        print("Workspace: %s/workbench" % environment["AA_DOC_FREE_URL"], flush=True)
        print("Access token: local .env → AA_DOC_FREE_TOKEN. Ctrl-C stops this workspace.", flush=True)
        while all(p.poll() is None for p in processes):
            time.sleep(1)
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
                process.kill(); process.wait()


if __name__ == "__main__":
    main()

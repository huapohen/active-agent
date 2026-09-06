import argparse
import getpass
import json
import logging
from pathlib import Path
from typing import Optional, Sequence

from .config import Settings, save_model_key
from .engine import ActiveAgent
from .models import MissionSpec, Mode, Risk
from .runtime import Runtime
from .store import Store


def main(argv: Optional[Sequence[str]] = None) -> None:
    parser = argparse.ArgumentParser(prog="active-agent")
    parser.add_argument("--db", help="SQLite database path")
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create", help="create a long-running mission")
    create.add_argument("conversation_id")
    create.add_argument("owner_id")
    create.add_argument("objective")
    create.add_argument("--mode", choices=[item.value for item in Mode], default=Mode.WATCH.value)
    create.add_argument("--risk", choices=[item.value for item in Risk], default=Risk.LOW.value)
    sub.add_parser("tick", help="evaluate due missions once")
    sub.add_parser("status", help="show missions and pending messages")
    sub.add_parser("worker", help="run the background evaluator")
    sub.add_parser("configure-model-key", help="securely prompt for and save the model key")
    sub.add_parser("documents", help="continuously collaborate on Doc Free mission documents")
    sub.add_parser("documents-tick", help="observe/evaluate document missions once")
    sub.add_parser("im", help="participate as an independent member in the native office IM")
    sub.add_parser("im-tick", help="claim and complete eligible native IM work once")
    sub.add_parser("im-fleet", help="run installed agent-store colleagues with independent identities")
    sub.add_parser("im-tools", help="discover every native office capability through MCP")
    im_call = sub.add_parser("im-call", help="invoke a native office tool; read its JSON arguments from stdin")
    im_call.add_argument("tool")
    args = parser.parse_args(argv)

    if args.command == "configure-model-key":
        save_model_key(getpass.getpass("Model API key (input hidden): "))
        print("Model key saved to the local ignored .env (mode 0600).")
        return

    settings = Settings.from_env()
    db_path = Path(args.db) if args.db else settings.db_path
    if args.command == "im-fleet":
        from .im_fleet import OfficeFleet
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
        try:
            OfficeFleet(settings).run()
        except KeyboardInterrupt:
            pass
        return
    if args.command in {"im-tools", "im-call"}:
        import sys
        from .im import IMClient
        params = {} if args.command == "im-tools" else {"name": args.tool, "arguments": json.load(sys.stdin)}
        output = IMClient(settings.doc_free_url, settings.im_token).request("POST", "/mcp", {
            "jsonrpc": "2.0", "id": 1, "method": "tools/list" if args.command == "im-tools" else "tools/call", "params": params})
        print(json.dumps(output, ensure_ascii=False, indent=2))
        return
    if args.command in {"im", "im-tick"}:
        from .im import IMAgent
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
        im_agent = IMAgent(settings)
        if args.command == "im-tick":
            print(json.dumps(im_agent.cycle(), ensure_ascii=False, indent=2))
        else:
            print("Active Agent is participating in the office IM. Ctrl-C to stop.", flush=True)
            try:
                im_agent.run()
            except KeyboardInterrupt:
                pass
        return
    if args.command in {"documents", "documents-tick"}:
        from dataclasses import replace
        from .documents import DocumentAgent
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
        document_agent = DocumentAgent(replace(settings, db_path=db_path))
        if args.command == "documents-tick":
            print(json.dumps(document_agent.cycle(), ensure_ascii=False, indent=2))
        else:
            print("Active Agent is watching Doc Free documents. Ctrl-C to stop.", flush=True)
            try:
                document_agent.run()
            except KeyboardInterrupt:
                pass
        return
    agent = ActiveAgent(Store(db_path), settings)
    if args.command == "create":
        output = agent.create_mission(MissionSpec(args.conversation_id, args.owner_id, args.objective, Mode(args.mode), risk=Risk(args.risk)))
    elif args.command == "tick":
        output = agent.run_cycle()
    elif args.command == "status":
        output = agent.status()
    else:
        runtime = Runtime(agent, settings.tick_seconds)
        runtime.start()
        print("Active Agent worker started; Ctrl-C to stop", flush=True)
        try:
            while True:
                runtime._stop.wait(3600)
        except KeyboardInterrupt:
            runtime.stop()
        return
    print(json.dumps(output, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

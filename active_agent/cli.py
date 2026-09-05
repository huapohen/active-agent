import argparse
import getpass
import json
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
    args = parser.parse_args(argv)

    if args.command == "configure-model-key":
        save_model_key(getpass.getpass("Model API key (input hidden): "))
        print("Model key saved to the local ignored .env (mode 0600).")
        return

    settings = Settings.from_env()
    db_path = Path(args.db) if args.db else settings.db_path
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

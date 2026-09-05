"""Minimal MCP stdio server exposing Active Agent as tools to other agents."""
import json
import sys
from typing import Any, Dict

from .config import Settings
from .engine import ActiveAgent
from .models import IncomingEvent, MissionSpec, Mode, Risk
from .store import Store


TOOLS = [
    {"name": "active_agent_ingest", "description": "Feed an IM or agent message into Active Agent", "inputSchema": {"type": "object", "required": ["conversation_id", "sender_id", "text"], "properties": {"conversation_id": {"type": "string"}, "sender_id": {"type": "string"}, "sender_name": {"type": "string"}, "text": {"type": "string"}, "event_id": {"type": "string"}, "metadata": {"type": "object"}}}},
    {"name": "active_agent_assign", "description": "Assign a recoverable long-running mission", "inputSchema": {"type": "object", "required": ["conversation_id", "owner_id", "objective"], "properties": {"conversation_id": {"type": "string"}, "owner_id": {"type": "string"}, "objective": {"type": "string"}, "mode": {"type": "string", "enum": [item.value for item in Mode]}, "risk": {"type": "string", "enum": [item.value for item in Risk]}, "success_criteria": {"type": "string"}, "notify_targets": {"type": "array", "items": {"type": "string"}}, "check_interval_seconds": {"type": "integer"}, "metadata": {"type": "object"}}}},
    {"name": "active_agent_status", "description": "Read missions and pending proactive messages", "inputSchema": {"type": "object", "properties": {"conversation_id": {"type": "string"}}}},
    {"name": "active_agent_tick", "description": "Evaluate due missions once", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "active_agent_approve", "description": "Approve or reject a proposed high-impact action", "inputSchema": {"type": "object", "required": ["approval_id", "approved", "actor_id"], "properties": {"approval_id": {"type": "string"}, "approved": {"type": "boolean"}, "actor_id": {"type": "string"}}}},
]


def content(value: Any, is_error: bool = False) -> Dict[str, Any]:
    return {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}], "isError": is_error}


def call(agent: ActiveAgent, name: str, args: Dict[str, Any]) -> Dict[str, Any]:
    if name == "active_agent_ingest":
        return content(agent.ingest(IncomingEvent(**args)))
    if name == "active_agent_assign":
        values = dict(args)
        values["mode"] = Mode(values.get("mode", Mode.WATCH.value))
        values["risk"] = Risk(values.get("risk", Risk.LOW.value))
        return content(agent.create_mission(MissionSpec(**values)))
    if name == "active_agent_status":
        return content(agent.status(args.get("conversation_id")))
    if name == "active_agent_tick":
        return content(agent.run_cycle())
    if name == "active_agent_approve":
        return content(agent.approve(args["approval_id"], args["approved"], args["actor_id"]))
    return content({"error": "unknown tool: " + name}, True)


def respond(message: Dict[str, Any], agent: ActiveAgent) -> Dict[str, Any]:
    method = message.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "active-agent", "version": "0.1.0"}}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        params = message.get("params", {})
        result = call(agent, params.get("name", ""), params.get("arguments", {}))
    elif method and method.startswith("notifications/"):
        return {}
    else:
        return {"jsonrpc": "2.0", "id": message.get("id"), "error": {"code": -32601, "message": "method not found"}}
    return {"jsonrpc": "2.0", "id": message.get("id"), "result": result}


def main() -> None:
    settings = Settings.from_env()
    agent = ActiveAgent(Store(settings.db_path), settings)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            response = respond(request, agent)
            if response:
                sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
                sys.stdout.flush()
        except Exception as exc:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32603, "message": exc.__class__.__name__}}) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()

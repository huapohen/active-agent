from typing import Any, Dict, Protocol


class ActiveAgentPlugin(Protocol):
    """In-process extension point. Plugins may enrich events or observe decisions."""

    def enrich_event(self, event: Dict[str, Any]) -> Dict[str, Any]: ...

    def on_decision(self, decision: Dict[str, Any]) -> None: ...


class NoopPlugin:
    def enrich_event(self, event: Dict[str, Any]) -> Dict[str, Any]:
        return event

    def on_decision(self, decision: Dict[str, Any]) -> None:
        return None


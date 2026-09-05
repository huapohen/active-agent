from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Dict, List, Optional
import uuid


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_id(prefix: str) -> str:
    return "%s_%s" % (prefix, uuid.uuid4().hex)


class Mode(str, Enum):
    TODO_STEWARD = "todo_steward"
    WATCH = "watch"
    PRIVATE_RESEARCH = "private_research"
    AGENT_COPILOT = "agent_copilot"
    ORCHESTRATOR = "orchestrator"


class MissionStatus(str, Enum):
    ACTIVE = "active"
    WAITING_APPROVAL = "waiting_approval"
    PAUSED = "paused"
    COMPLETED = "completed"
    CANCELLED = "cancelled"


class Risk(str, Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"


@dataclass
class IncomingEvent:
    conversation_id: str
    sender_id: str
    text: str
    event_id: str = field(default_factory=lambda: new_id("evt"))
    sender_name: str = ""
    occurred_at: str = field(default_factory=utc_now)
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class MissionSpec:
    conversation_id: str
    owner_id: str
    objective: str
    mode: Mode = Mode.WATCH
    success_criteria: str = ""
    notify_targets: List[str] = field(default_factory=list)
    check_interval_seconds: int = 300
    deadline: Optional[str] = None
    risk: Risk = Risk.LOW
    metadata: Dict[str, Any] = field(default_factory=dict)


import hmac
from pathlib import Path
from typing import Any, Dict, List, Optional

from .config import Settings
from .engine import ActiveAgent
from .models import IncomingEvent, MissionSpec, Mode, Risk
from .store import Store


def create_app(settings: Optional[Settings] = None):
    try:
        from fastapi import Depends, FastAPI, Header, HTTPException
        from fastapi.responses import HTMLResponse
        from pydantic import BaseModel, Field
    except ImportError as exc:
        raise RuntimeError("Install API dependencies with: pip install -e '.[api]'") from exc

    settings = settings or Settings.from_env()
    agent = ActiveAgent(Store(settings.db_path), settings)
    app = FastAPI(title="Active Agent", version="0.1.0")
    web_root = Path(__file__).with_name("web")

    class EventBody(BaseModel):
        conversation_id: str
        sender_id: str
        text: str
        event_id: Optional[str] = None
        sender_name: str = ""
        occurred_at: Optional[str] = None
        metadata: Dict[str, Any] = Field(default_factory=dict)

    class MissionBody(BaseModel):
        conversation_id: str
        owner_id: str
        objective: str
        mode: Mode = Mode.WATCH
        success_criteria: str = ""
        notify_targets: List[str] = Field(default_factory=list)
        check_interval_seconds: int = 300
        deadline: Optional[str] = None
        risk: Risk = Risk.LOW
        metadata: Dict[str, Any] = Field(default_factory=dict)

    class ApprovalBody(BaseModel):
        approved: bool
        actor_id: str

    def authorize(authorization: Optional[str] = Header(default=None)) -> None:
        if not settings.api_token:
            return
        expected = "Bearer " + settings.api_token
        if not authorization or not hmac.compare_digest(authorization, expected):
            raise HTTPException(401, "invalid bearer token")

    @app.get("/health")
    def health():
        return {"ok": True, "service": "active-agent", "version": "0.1.0"}

    @app.get("/", response_class=HTMLResponse, include_in_schema=False)
    def console():
        return (web_root / "index.html").read_text(encoding="utf-8")

    @app.get("/architecture", response_class=HTMLResponse, include_in_schema=False)
    def architecture():
        return (Path(__file__).parent.parent / "docs" / "technical-architecture.html").read_text(encoding="utf-8")

    @app.post("/v1/events", dependencies=[Depends(authorize)])
    def ingest(body: EventBody):
        values = body.model_dump(exclude_none=True) if hasattr(body, "model_dump") else body.dict(exclude_none=True)
        return agent.ingest(IncomingEvent(**values))

    @app.post("/v1/missions", dependencies=[Depends(authorize)])
    def create_mission(body: MissionBody):
        values = body.model_dump() if hasattr(body, "model_dump") else body.dict()
        return agent.create_mission(MissionSpec(**values))

    @app.get("/v1/missions", dependencies=[Depends(authorize)])
    def missions(conversation_id: Optional[str] = None, status: Optional[str] = None):
        return agent.store.list_missions(conversation_id, status)

    @app.get("/v1/conversations/{conversation_id}/events", dependencies=[Depends(authorize)])
    def events(conversation_id: str, limit: int = 100):
        return agent.store.recent_events(conversation_id, min(max(limit, 1), 500))

    @app.get("/v1/missions/{mission_id}/evidence", dependencies=[Depends(authorize)])
    def evidence(mission_id: str, limit: int = 100):
        if not agent.store.get_mission(mission_id):
            raise HTTPException(404, "mission not found")
        return agent.store.evidence(mission_id, min(max(limit, 1), 500))

    @app.post("/v1/cycles", dependencies=[Depends(authorize)])
    def cycle():
        return agent.run_cycle()

    @app.get("/v1/outbox", dependencies=[Depends(authorize)])
    def outbox():
        return agent.store.pending_outbox()

    @app.post("/v1/outbox/{outbox_id}/delivered", dependencies=[Depends(authorize)])
    def delivered(outbox_id: str):
        agent.store.mark_delivered(outbox_id)
        return {"ok": True}

    @app.post("/v1/approvals/{approval_id}", dependencies=[Depends(authorize)])
    def approve(approval_id: str, body: ApprovalBody):
        result = agent.approve(approval_id, body.approved, body.actor_id)
        if not result:
            raise HTTPException(404, "pending approval not found")
        return result

    app.state.active_agent = agent
    return app


try:
    app = create_app()
except RuntimeError:
    app = None

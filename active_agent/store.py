import json
from contextlib import contextmanager
from pathlib import Path
import sqlite3
from typing import Any, Dict, Iterable, List, Optional

from .models import IncomingEvent, MissionSpec, MissionStatus, new_id, utc_now


SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS events (
  event_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, sender_id TEXT NOT NULL,
  sender_name TEXT NOT NULL, text TEXT NOT NULL, occurred_at TEXT NOT NULL, metadata_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_conversation ON events(conversation_id, occurred_at);
CREATE TABLE IF NOT EXISTS missions (
  mission_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, owner_id TEXT NOT NULL,
  objective TEXT NOT NULL, mode TEXT NOT NULL, success_criteria TEXT NOT NULL,
  notify_targets_json TEXT NOT NULL, check_interval_seconds INTEGER NOT NULL,
  deadline TEXT, risk TEXT NOT NULL, status TEXT NOT NULL, next_check_at TEXT NOT NULL,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, metadata_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_missions_due ON missions(status, next_check_at);
CREATE TABLE IF NOT EXISTS evidence (
  evidence_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL REFERENCES missions(mission_id),
  event_id TEXT, summary TEXT NOT NULL, relevance REAL NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS decisions (
  decision_id TEXT PRIMARY KEY, mission_id TEXT REFERENCES missions(mission_id),
  kind TEXT NOT NULL, rationale TEXT NOT NULL, payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS outbox (
  outbox_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, mission_id TEXT,
  text TEXT NOT NULL, target_ids_json TEXT NOT NULL, status TEXT NOT NULL,
  dedupe_key TEXT UNIQUE, created_at TEXT NOT NULL, delivered_at TEXT
);
CREATE TABLE IF NOT EXISTS approvals (
  approval_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL REFERENCES missions(mission_id),
  action_json TEXT NOT NULL, status TEXT NOT NULL, requested_at TEXT NOT NULL,
  resolved_at TEXT, resolved_by TEXT
);
CREATE TABLE IF NOT EXISTS leases (
  name TEXT PRIMARY KEY, owner TEXT NOT NULL, expires_at TEXT NOT NULL
);
"""


class Store:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as conn:
            conn.executescript(SCHEMA)

    @contextmanager
    def connect(self):
        conn = sqlite3.connect(str(self.path), timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys=ON")
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    @staticmethod
    def _dict(row: sqlite3.Row) -> Dict[str, Any]:
        item = dict(row)
        for key in list(item):
            if key.endswith("_json"):
                item[key[:-5]] = json.loads(item.pop(key))
        return item

    def append_event(self, event: IncomingEvent) -> bool:
        with self.connect() as conn:
            cursor = conn.execute(
                "INSERT OR IGNORE INTO events VALUES(?,?,?,?,?,?,?)",
                (event.event_id, event.conversation_id, event.sender_id, event.sender_name,
                 event.text, event.occurred_at, json.dumps(event.metadata, ensure_ascii=False)),
            )
            return cursor.rowcount == 1

    def recent_events(self, conversation_id: str, limit: int = 100) -> List[Dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM events WHERE conversation_id=? ORDER BY occurred_at DESC LIMIT ?",
                (conversation_id, limit),
            ).fetchall()
        return [self._dict(row) for row in reversed(rows)]

    def create_mission(self, spec: MissionSpec) -> Dict[str, Any]:
        mission_id, now = new_id("msn"), utc_now()
        with self.connect() as conn:
            conn.execute(
                "INSERT INTO missions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (mission_id, spec.conversation_id, spec.owner_id, spec.objective, spec.mode.value,
                 spec.success_criteria, json.dumps(spec.notify_targets, ensure_ascii=False),
                 max(5, spec.check_interval_seconds), spec.deadline, spec.risk.value,
                 MissionStatus.ACTIVE.value, now, now, now,
                 json.dumps(spec.metadata, ensure_ascii=False)),
            )
        return self.get_mission(mission_id) or {}

    def get_mission(self, mission_id: str) -> Optional[Dict[str, Any]]:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM missions WHERE mission_id=?", (mission_id,)).fetchone()
        return self._dict(row) if row else None

    def list_missions(self, conversation_id: Optional[str] = None, status: Optional[str] = None) -> List[Dict[str, Any]]:
        clauses, values = [], []
        if conversation_id:
            clauses.append("conversation_id=?"); values.append(conversation_id)
        if status:
            clauses.append("status=?"); values.append(status)
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        with self.connect() as conn:
            rows = conn.execute("SELECT * FROM missions" + where + " ORDER BY created_at", values).fetchall()
        return [self._dict(row) for row in rows]

    def due_missions(self, now: str, limit: int = 50) -> List[Dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM missions WHERE status='active' AND next_check_at<=? ORDER BY next_check_at LIMIT ?",
                (now, limit),
            ).fetchall()
        return [self._dict(row) for row in rows]

    def update_mission(self, mission_id: str, **values: Any) -> None:
        allowed = {"status", "next_check_at", "success_criteria", "metadata_json"}
        values = {key: value for key, value in values.items() if key in allowed}
        if not values:
            return
        values["updated_at"] = utc_now()
        sql = "UPDATE missions SET " + ",".join("%s=?" % key for key in values) + " WHERE mission_id=?"
        with self.connect() as conn:
            conn.execute(sql, list(values.values()) + [mission_id])

    def add_evidence(self, mission_id: str, summary: str, event_id: Optional[str] = None, relevance: float = 1.0) -> str:
        evidence_id = new_id("evd")
        with self.connect() as conn:
            conn.execute("INSERT INTO evidence VALUES(?,?,?,?,?,?)", (evidence_id, mission_id, event_id, summary, relevance, utc_now()))
        return evidence_id

    def evidence(self, mission_id: str, limit: int = 100) -> List[Dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute("SELECT * FROM evidence WHERE mission_id=? ORDER BY created_at DESC LIMIT ?", (mission_id, limit)).fetchall()
        return [self._dict(row) for row in rows]

    def record_decision(self, mission_id: Optional[str], kind: str, rationale: str, payload: Dict[str, Any]) -> str:
        decision_id = new_id("dec")
        with self.connect() as conn:
            conn.execute("INSERT INTO decisions VALUES(?,?,?,?,?,?)", (decision_id, mission_id, kind, rationale, json.dumps(payload, ensure_ascii=False), utc_now()))
        return decision_id

    def enqueue(self, conversation_id: str, text: str, mission_id: Optional[str], targets: Iterable[str], dedupe_key: str) -> Optional[str]:
        outbox_id = new_id("out")
        with self.connect() as conn:
            cursor = conn.execute(
                "INSERT OR IGNORE INTO outbox VALUES(?,?,?,?,?,?,?,?,NULL)",
                (outbox_id, conversation_id, mission_id, text, json.dumps(list(targets), ensure_ascii=False), "pending", dedupe_key, utc_now()),
            )
        return outbox_id if cursor.rowcount == 1 else None

    def pending_outbox(self, limit: int = 100) -> List[Dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute("SELECT * FROM outbox WHERE status='pending' ORDER BY created_at LIMIT ?", (limit,)).fetchall()
        return [self._dict(row) for row in rows]

    def mark_delivered(self, outbox_id: str) -> None:
        with self.connect() as conn:
            conn.execute("UPDATE outbox SET status='delivered', delivered_at=? WHERE outbox_id=?", (utc_now(), outbox_id))

    def request_approval(self, mission_id: str, action: Dict[str, Any]) -> str:
        approval_id = new_id("apr")
        with self.connect() as conn:
            conn.execute("INSERT INTO approvals VALUES(?,?,?,?,?,NULL,NULL)", (approval_id, mission_id, json.dumps(action, ensure_ascii=False), "pending", utc_now()))
            conn.execute("UPDATE missions SET status=?,updated_at=? WHERE mission_id=?", (MissionStatus.WAITING_APPROVAL.value, utc_now(), mission_id))
        return approval_id

    def resolve_approval(self, approval_id: str, approved: bool, resolved_by: str) -> Optional[Dict[str, Any]]:
        status = "approved" if approved else "rejected"
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM approvals WHERE approval_id=? AND status='pending'", (approval_id,)).fetchone()
            if not row:
                return None
            conn.execute("UPDATE approvals SET status=?,resolved_at=?,resolved_by=? WHERE approval_id=?", (status, utc_now(), resolved_by, approval_id))
            conn.execute("UPDATE missions SET status=?,updated_at=? WHERE mission_id=?", (MissionStatus.ACTIVE.value if approved else MissionStatus.PAUSED.value, utc_now(), row["mission_id"]))
            updated = conn.execute("SELECT * FROM approvals WHERE approval_id=?", (approval_id,)).fetchone()
        return self._dict(updated)

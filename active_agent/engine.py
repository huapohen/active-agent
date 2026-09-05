from dataclasses import asdict
from datetime import datetime, timedelta, timezone
import json
import re
from typing import Any, Dict, Iterable, List, Optional

from .config import Settings
from .llm import OpenAICompatibleModel
from .models import IncomingEvent, MissionSpec, Mode, Risk, utc_now
from .plugins import ActiveAgentPlugin, NoopPlugin
from .policy import Evaluation, Evaluator, relevance
from .store import Store


ASSIGNMENT_WORDS = ("帮我", "替我", "留意", "盯一下", "监督", "持续关注", "记得")


class ActiveAgent:
    def __init__(self, store: Store, settings: Optional[Settings] = None, plugins: Optional[Iterable[ActiveAgentPlugin]] = None):
        self.store = store
        self.settings = settings or Settings()
        model = None
        if self.settings.model_api_key:
            model = OpenAICompatibleModel(self.settings.model_api_key, self.settings.model_base_url,
                self.settings.model_name, self.settings.model_timeout, self.settings.model_reasoning_effort, self.settings.model_api_style)
        self.evaluator = Evaluator(model)
        self.plugins = list(plugins or [NoopPlugin()])

    def ingest(self, event: IncomingEvent) -> Dict[str, Any]:
        payload = asdict(event)
        for plugin in self.plugins:
            payload = plugin.enrich_event(payload)
        event = IncomingEvent(**payload)
        if not self.store.append_event(event):
            return {"accepted": False, "reason": "duplicate", "event_id": event.event_id}

        attached = []
        for mission in self.store.list_missions(event.conversation_id, "active"):
            score = relevance(mission["objective"], event.text)
            explicit = event.metadata.get("mission_id") == mission["mission_id"]
            if explicit or score >= float(mission["metadata"].get("relevance_threshold", 0.25)):
                self.store.add_evidence(mission["mission_id"], event.text, event.event_id, 1.0 if explicit else score)
                if self.settings.min_silence_seconds:
                    quiet_until = (datetime.now(timezone.utc) + timedelta(seconds=self.settings.min_silence_seconds)).isoformat()
                    self.store.update_mission(mission["mission_id"], next_check_at=quiet_until)
                attached.append(mission["mission_id"])

        created = None
        if self.settings.mention.lower() in event.text.lower() and any(word in event.text for word in ASSIGNMENT_WORDS):
            objective = self._objective_from_mention(event.text)
            if objective:
                spec = MissionSpec(event.conversation_id, event.sender_id, objective, self._infer_mode(objective), risk=self._infer_risk(objective))
                created = self.create_mission(spec)
                self.store.add_evidence(created["mission_id"], "任务由 %s 在群聊中明确交代" % (event.sender_name or event.sender_id), event.event_id)
        return {"accepted": True, "event_id": event.event_id, "attached_missions": attached, "created_mission": created}

    def create_mission(self, spec: MissionSpec) -> Dict[str, Any]:
        mission = self.store.create_mission(spec)
        if self.settings.min_silence_seconds:
            quiet_until = (datetime.now(timezone.utc) + timedelta(seconds=self.settings.min_silence_seconds)).isoformat()
            self.store.update_mission(mission["mission_id"], next_check_at=quiet_until)
            mission = self.store.get_mission(mission["mission_id"]) or mission
        self.store.record_decision(mission["mission_id"], "mission_created", "收到明确委托", {"mode": spec.mode.value, "risk": spec.risk.value})
        return mission

    def run_cycle(self, now: Optional[str] = None) -> Dict[str, Any]:
        now = now or utc_now()
        results = []
        for mission in self.store.due_missions(now):
            events = self.store.recent_events(mission["conversation_id"], 100)
            evidence = self.store.evidence(mission["mission_id"], 100)
            evaluation = self.evaluator.evaluate(mission, events, evidence)
            result = self._apply(mission, evaluation, len(evidence), now)
            results.append(result)
        return {"checked": len(results), "results": results, "at": now}

    def _apply(self, mission: Dict[str, Any], evaluation: Evaluation, evidence_count: int, now: str) -> Dict[str, Any]:
        payload = {"action": evaluation.action, "confidence": evaluation.confidence, "requires_approval": evaluation.requires_approval}
        decision_id = self.store.record_decision(mission["mission_id"], "evaluation", evaluation.rationale, payload)
        for plugin in self.plugins:
            plugin.on_decision({"decision_id": decision_id, "mission": mission, "evaluation": payload})

        output_id, approval_id = None, None
        if evaluation.action == "propose_action" or evaluation.requires_approval:
            approval_id = self.store.request_approval(mission["mission_id"], evaluation.proposed_action or payload)
            if evaluation.message:
                output_id = self.store.enqueue(mission["conversation_id"], evaluation.message, mission["mission_id"], mission["notify_targets"], "approval:" + approval_id)
        elif evaluation.action in {"notify", "complete"} and evaluation.message:
            output_id = self.store.enqueue(mission["conversation_id"], evaluation.message, mission["mission_id"], mission["notify_targets"], "decision:" + decision_id)
            if evaluation.action == "complete":
                self.store.update_mission(mission["mission_id"], status="completed")

        metadata = dict(mission["metadata"])
        metadata["evaluated_evidence_count"] = evidence_count
        next_at = (datetime.fromisoformat(now) + timedelta(seconds=mission["check_interval_seconds"])).isoformat()
        self.store.update_mission(mission["mission_id"], next_check_at=next_at, metadata_json=json.dumps(metadata, ensure_ascii=False))
        return {"mission_id": mission["mission_id"], "action": evaluation.action, "decision_id": decision_id, "outbox_id": output_id, "approval_id": approval_id}

    def approve(self, approval_id: str, approved: bool, actor_id: str) -> Optional[Dict[str, Any]]:
        return self.store.resolve_approval(approval_id, approved, actor_id)

    def status(self, conversation_id: Optional[str] = None) -> Dict[str, Any]:
        return {"missions": self.store.list_missions(conversation_id), "outbox": self.store.pending_outbox()}

    def _objective_from_mention(self, text: str) -> str:
        objective = re.sub(re.escape(self.settings.mention), "", text, flags=re.IGNORECASE).strip(" ：:，,。 \n")
        return objective[:2000]

    @staticmethod
    def _infer_mode(objective: str) -> Mode:
        if any(word in objective for word in ("组建", "拉几个", "协调", "团队", "分工")):
            return Mode.ORCHESTRATOR
        if any(word in objective for word in ("资料", "够了", "方案", "技术栈")):
            return Mode.PRIVATE_RESEARCH
        if any(word in objective for word in ("todo", "待办", "提醒谁", "监督")):
            return Mode.TODO_STEWARD
        return Mode.WATCH

    @staticmethod
    def _infer_risk(objective: str) -> Risk:
        if any(word in objective for word in ("股票", "买入", "卖出", "付款", "删除", "转账", "投资", "招聘", "资源")):
            return Risk.HIGH
        return Risk.LOW

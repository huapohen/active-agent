from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Set
import re

from .llm import ModelError, OpenAICompatibleModel, render_context


@dataclass
class Evaluation:
    action: str
    rationale: str
    message: str = ""
    confidence: float = 0.0
    requires_approval: bool = False
    proposed_action: Optional[Dict[str, Any]] = None


SYSTEM_PROMPT = """你是主动式智能体的审慎决策器。你的工作不是回答聊天，而是判断现在是否值得主动介入。
只有出现新的、任务相关且可行动的信息，或明确风险/阻塞/达成条件时才 notify；信息不足就 stay_silent。
不要把周期本身当触发理由，不复述隐私或凭据，不承诺没有证据的结论。涉及交易、付款、删除、对外发送、增减企业资源或组建团队执行时 requires_approval=true。
输出 JSON：action(stay_silent|notify|complete|propose_action), rationale, message, confidence(0..1), requires_approval, proposed_action(object|null)。"""


class Evaluator:
    def __init__(self, model: Optional[OpenAICompatibleModel] = None):
        self.model = model

    def evaluate(self, mission: Dict[str, Any], events: List[Dict[str, Any]], evidence: List[Dict[str, Any]]) -> Evaluation:
        seen = int(mission.get("metadata", {}).get("evaluated_evidence_count", 0))
        if len(evidence) <= seen:
            return Evaluation("stay_silent", "没有新增的任务相关线索")
        if self.model:
            try:
                raw = self.model.complete_json(SYSTEM_PROMPT, render_context(mission, events, evidence))
                return self._from_model(raw)
            except ModelError:
                pass
        return self._rules(mission, evidence)

    @staticmethod
    def _from_model(raw: Dict[str, Any]) -> Evaluation:
        allowed = {"stay_silent", "notify", "complete", "propose_action"}
        action = str(raw.get("action", "stay_silent"))
        if action not in allowed:
            action = "stay_silent"
        confidence = max(0.0, min(1.0, float(raw.get("confidence", 0))))
        if action != "stay_silent" and confidence < 0.65:
            action = "stay_silent"
        return Evaluation(
            action=action,
            rationale=str(raw.get("rationale", "model evaluation")),
            message=str(raw.get("message", "")),
            confidence=confidence,
            requires_approval=bool(raw.get("requires_approval", False)),
            proposed_action=raw.get("proposed_action") if isinstance(raw.get("proposed_action"), dict) else None,
        )

    @staticmethod
    def _rules(mission: Dict[str, Any], evidence: List[Dict[str, Any]]) -> Evaluation:
        metadata = mission.get("metadata", {})
        seen = int(metadata.get("evaluated_evidence_count", 0))
        new_count = max(0, len(evidence) - seen)
        if new_count == 0:
            return Evaluation("stay_silent", "没有新增的任务相关线索")
        mode = mission["mode"]
        threshold = int(metadata.get("evidence_threshold", 1 if mode in {"todo_steward", "watch"} else 3))
        if len(evidence) < threshold:
            return Evaluation("stay_silent", "线索仍未达到任务设定的充分性阈值")
        newest = evidence[0]["summary"]
        if mode == "orchestrator":
            return Evaluation(
                "propose_action", "开放任务已经积累到可拆解阶段", "我已经形成初步分工方案，等待你确认后再调度其他 Agent。",
                0.8, True, {"type": "delegate", "objective": mission["objective"]},
            )
        message = "任务「%s」有了值得关注的新进展：%s" % (mission["objective"], newest)
        return Evaluation("notify", "出现新的相关证据并达到充分性阈值", message, 0.75)


def tokens(text: str) -> Set[str]:
    english = re.findall(r"[a-zA-Z0-9_]{2,}", text.lower())
    chinese = re.findall(r"[\u4e00-\u9fff]{2,}", text)
    pieces: Set[str] = set(english)
    for run in chinese:
        pieces.update(run[index:index + 2] for index in range(len(run) - 1))
    stop = {"帮我", "看看", "这个", "那个", "可以", "需要", "一下", "什么", "时候"}
    return pieces - stop


def relevance(objective: str, message: str) -> float:
    left, right = tokens(objective), tokens(message)
    if not left or not right:
        return 0.0
    common = left & right
    return min(1.0, len(common) / max(1.0, min(len(left), 4.0)))

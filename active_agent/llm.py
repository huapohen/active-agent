import json
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional


class ModelError(RuntimeError):
    pass


class OpenAICompatibleModel:
    """Small dependency-free adapter for DeepSeek/DashScope/OpenAI-compatible APIs."""

    def __init__(self, api_key: str, base_url: str, model: str, timeout: int = 60):
        self.api_key = api_key
        base_url = base_url.rstrip("/")
        self.chat_url = base_url + "/chat/completions" if base_url.endswith("/v1") else base_url + "/v1/chat/completions"
        self.model = model
        self.timeout = timeout

    def complete_json(self, system: str, user: str) -> Dict[str, Any]:
        body = json.dumps({
            "model": self.model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "temperature": 0.1,
            "response_format": {"type": "json_object"},
        }).encode("utf-8")
        request = urllib.request.Request(
            self.chat_url,
            data=body,
            headers={"Authorization": "Bearer " + self.api_key, "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                data = json.loads(response.read().decode("utf-8"))
            content = data["choices"][0]["message"]["content"]
            return json.loads(content)
        except (KeyError, ValueError, urllib.error.URLError) as exc:
            raise ModelError("model request failed: %s" % exc.__class__.__name__) from exc


def render_context(mission: Dict[str, Any], events: List[Dict[str, Any]], evidence: List[Dict[str, Any]]) -> str:
    safe_mission = {key: value for key, value in mission.items() if key not in {"metadata"}}
    safe_events = [{"sender": item["sender_name"] or item["sender_id"], "text": item["text"], "at": item["occurred_at"]} for item in events[-40:]]
    safe_evidence = [{"summary": item["summary"], "at": item["created_at"]} for item in evidence[:30]]
    return json.dumps({"mission": safe_mission, "recent_events": safe_events, "evidence": safe_evidence}, ensure_ascii=False)

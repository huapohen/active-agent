import json
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional


class ModelError(RuntimeError):
    pass


class OpenAICompatibleModel:
    """Small dependency-free adapter for DeepSeek/DashScope/OpenAI-compatible APIs."""

    def __init__(self, api_key: str, base_url: str, model: str, timeout: int = 90, reasoning_effort: str = "medium", api_style: str = "chat"):
        self.api_key = api_key
        base_url = base_url.rstrip("/")
        self.chat_url = base_url + "/chat/completions" if base_url.endswith("/v1") else base_url + "/v1/chat/completions"
        self.responses_url = self.chat_url.replace("/chat/completions", "/responses")
        if api_style not in {"chat", "responses"}:
            raise ValueError("AA_MODEL_API_STYLE must be chat or responses")
        self.api_style = api_style
        self.last_response_metadata = {}
        self.model = model
        self.timeout = timeout
        if reasoning_effort not in {"none", "minimal", "low", "medium", "high", "xhigh"}:
            raise ValueError("unsupported reasoning effort")
        self.reasoning_effort = reasoning_effort

    def complete_json(self, system: str, user: str) -> Dict[str, Any]:
        payload = {
            "model": self.model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "reasoning_effort": self.reasoning_effort,
            "response_format": {"type": "json_object"},
        }
        if self.api_style == "responses":
            payload = {"model": self.model, "instructions": system,
                "input": [{"role": "user", "content": [{"type": "input_text", "text": user}]}],
                "reasoning": {"effort": self.reasoning_effort}, "store": False, "stream": True}
        body = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            self.responses_url if self.api_style == "responses" else self.chat_url,
            data=body,
            headers={"Authorization": "Bearer " + self.api_key, "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                if self.api_style == "responses":
                    content = self._read_response(response)
                else:
                    data = json.loads(response.read(8_000_001).decode("utf-8"))
                    content = data["choices"][0]["message"]["content"]
            result = json.loads(content)
            if not isinstance(result, dict):
                raise ValueError("expected a JSON object")
            return result
        except urllib.error.HTTPError as exc:
            # Never include provider response bodies, request headers or chained secrets.
            raise ModelError("model request failed: HTTP %s" % exc.code) from None
        except (KeyError, IndexError, TypeError, ValueError, OSError) as exc:
            raise ModelError("model request failed: %s" % exc.__class__.__name__) from None

    def _final_text(self, response, completed_text=None):
        if not isinstance(response, dict):
            raise ModelError("invalid model response object")
        if response.get("status") != "completed" or response.get("error"):
            raise ModelError("model response did not complete")
        usage = response.get("usage") if isinstance(response.get("usage"), dict) else {}
        self.last_response_metadata = {"model": response.get("model"), "usage": {
            k: v for k, v in usage.items()
            if k in {"input_tokens", "output_tokens", "total_tokens"} and isinstance(v, int)}}
        output = response.get("output", [])
        if not isinstance(output, list) or any(not isinstance(item, dict) or
            not isinstance(item.get("content", []), list) or any(not isinstance(part, dict)
                for part in item.get("content", [])) for item in output):
            raise ModelError("invalid model output structure")
        text = "".join(part.get("text", "") for item in output
            for part in item.get("content", []) if part.get("type") == "output_text")
        # Some gateways omit output in response.completed, but emit output_text.done.
        # Only those finalized items are eligible; delta fragments are never committed.
        text = text or "".join(value for _, value in sorted((completed_text or {}).items()))
        if not text:
            raise ModelError("model completed without output text")
        return text

    def _read_response(self, response):
        if "text/event-stream" not in response.headers.get("content-type", ""):
            return self._final_text(json.loads(response.read(8_000_001).decode("utf-8")))
        lines, completed_text, size = [], {}, 0
        for line in response:
            size += len(line)
            if size > 8_000_000:
                raise ModelError("model response exceeded byte budget")
            value = line.decode("utf-8").rstrip("\r\n")
            if value.startswith("data:"):
                lines.append(value[5:].lstrip())
            elif not value and lines:
                data, lines = "\n".join(lines), []
                if data == "[DONE]":
                    break
                event = json.loads(data)
                if not isinstance(event, dict):
                    raise ModelError("invalid model stream event")
                kind = event.get("type")
                if kind in {"error", "response.failed", "response.incomplete"}:
                    raise ModelError("model stream failed or incomplete")
                if kind == "response.output_text.done":
                    completed_text[(event.get("output_index", 0), event.get("content_index", 0))] = event["text"]
                if kind == "response.completed":
                    return self._final_text(event["response"], completed_text)
        raise ModelError("model stream ended before response.completed")


def render_context(mission: Dict[str, Any], events: List[Dict[str, Any]], evidence: List[Dict[str, Any]]) -> str:
    safe_mission = {key: value for key, value in mission.items() if key not in {"metadata"}}
    safe_events = [{"sender": item["sender_name"] or item["sender_id"], "text": item["text"], "at": item["occurred_at"]} for item in events[-40:]]
    safe_evidence = [{"summary": item["summary"], "at": item["created_at"]} for item in evidence[:30]]
    return json.dumps({"mission": safe_mission, "recent_events": safe_events, "evidence": safe_evidence}, ensure_ascii=False)

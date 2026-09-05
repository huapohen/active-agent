import json
import unittest
from active_agent.llm import OpenAICompatibleModel, ModelError


class Stream:
    headers = {"content-type": "text/event-stream"}
    def __init__(self, events):
        self.lines = ("".join("data: " + json.dumps(e) + "\n\n" for e in events)).encode().splitlines(keepends=True)
    def __iter__(self): return iter(self.lines)


class ResponsesTest(unittest.TestCase):
    def setUp(self):
        self.model = OpenAICompatibleModel("test-only", "https://provider.test/v1", "gpt-6-astra", api_style="responses")

    def test_gateway_omitting_final_output_uses_done_item_after_completion(self):
        stream = Stream([
            {"type": "response.output_text.delta", "delta": "partial"},
            {"type": "response.output_text.done", "text": '{"ok":true}'},
            {"type": "response.completed", "response": {"status": "completed", "output": [], "model": "gpt-6-astra"}},
        ])
        self.assertEqual(json.loads(self.model._read_response(stream)), {"ok": True})

    def test_disconnect_never_commits_partial_output(self):
        with self.assertRaises(ModelError):
            self.model._read_response(Stream([{"type": "response.output_text.done", "text": '{"ok":true}'}]))

    def test_delta_only_completion_is_rejected(self):
        with self.assertRaises(ModelError):
            self.model._read_response(Stream([
                {"type": "response.output_text.delta", "delta": '{"ok":true}'},
                {"type": "response.completed", "response": {"status": "completed", "output": []}},
            ]))

    def test_incomplete_response_is_rejected(self):
        with self.assertRaises(ModelError):
            self.model._read_response(Stream([{"type": "response.incomplete"}]))

    def test_malformed_stream_event_is_rejected(self):
        with self.assertRaises(ModelError):
            self.model._read_response(Stream([["unexpected"]]))

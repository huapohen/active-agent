import copy
import unittest
from dataclasses import replace

from active_agent.config import Settings
from active_agent.im import IMAgent, normalize_im_rich_text
from active_agent.llm import ModelError
from tests.test_im import Model, RoomService
from tests.test_im_actions import ActionService, decision


def rich(start=0, end=2, styles=None):
    return {"version": 1, "spans": [{"start": start, "end": end, "styles": styles or ["bold"]}]}


class NativeRichTextWorkerTests(unittest.TestCase):
    def setUp(self):
        self.settings = replace(Settings(), model_name="test-model", model_reasoning_effort="medium", im_token="test-agent")

    def test_plain_null_and_empty_styles_preserve_legacy_payload(self):
        plain = {"action": "reply", "content": "Text", "rationale": "Visible work"}
        expected = {**plain, "mentions": [], "artifact": None}
        for extra in [{}, {"rich_text": None}, {"rich_text": {"version": 1, "spans": []}}]:
            self.assertEqual(IMAgent.validate({**plain, **extra}, {}), expected)

    def test_utf16_boundaries_match_astral_and_explicit_surrogate_pairs(self):
        expected = {"version": 1, "spans": [rich(0, 2, ["italic"])["spans"][0], rich(2, 4, ["bold", "underline"])["spans"][0]]}
        provided = {"version": 1, "spans": [rich(2, 4, ["underline", "bold", "bold"])["spans"][0], rich(0, 2, ["italic"])["spans"][0]]}
        for text in ["😀ab", "\ud83d\ude00ab"]:
            self.assertEqual(normalize_im_rich_text(provided, text), expected)
            for value in [rich(0, 1), rich(1, 2), rich(0, 5)]:
                with self.assertRaises(ModelError):
                    normalize_im_rich_text(value, text)

    def test_style_shape_bounds_and_boolean_offsets_are_rejected(self):
        for value in [{**rich(), "version": True}, rich(False, 2), rich(0, 2.5), rich(-1, 2),
                      rich(0, 2, ["html"]), {**rich(), "html": "unsupported"},
                      {"version": 1, "spans": rich()["spans"] * 201}, {"version": 1, "spans": [None]}]:
            with self.assertRaises(ModelError):
                normalize_im_rich_text(value, "ABCD")
        self.assertEqual(normalize_im_rich_text({"version": 1.0, "spans": [{"start": 0.0, "end": 2.0, "styles": ["bold"]}]}, "😀ab"), rich())
        with self.assertRaises(ModelError):
            IMAgent.validate({"action": "silent", "rationale": "No change", "rich_text": rich()}, {})

    def test_standard_worker_sends_style_and_retries_identical_completion(self):
        service = RoomService()
        service.ambiguous = True
        output = {"action": "reply", "content": "😀 styled result", "rationale": "Useful result", "rich_text": rich()}
        model = Model(output)
        IMAgent(self.settings, service, model).cycle()
        self.assertEqual(service.finish_calls[0]["rich_text"], output["rich_text"])
        self.assertEqual(service.finish_calls[0], service.finish_calls[1])
        self.assertEqual(len(model.calls), 1)
        self.assertIn("UTF-16", model.calls[0][0])

    def test_invalid_model_styles_block_instead_of_silently_dropping_format(self):
        service = RoomService()
        output = {"action": "reply", "content": "😀 result", "rationale": "Useful result", "rich_text": rich(0, 1)}
        IMAgent(self.settings, service, Model(output)).cycle()
        self.assertEqual(service.finish_calls[0]["action"], "blocked")
        self.assertNotIn("rich_text", service.finish_calls[0])
        self.assertEqual(service.finish_calls[0]["content"], "")

    def test_frozen_styled_plan_resumes_without_losing_final_result(self):
        service = ActionService()
        service.disconnect_second = True
        output = decision()
        output["rich_text"] = rich(0, 3, ["bold", "strikethrough"])
        IMAgent(self.settings, service, Model(output)).cycle()
        self.assertEqual(service.plan_calls[0]["final_result"]["rich_text"], output["rich_text"])
        frozen = copy.deepcopy(service.plan)
        service.disconnect_second = False
        model = Model(ModelError("must not re-infer"))
        IMAgent(self.settings, service, model).cycle()
        self.assertEqual(model.calls, [])
        self.assertEqual(service.plan, frozen)
        self.assertEqual(service.finish_calls[0]["rich_text"], output["rich_text"])


if __name__ == "__main__":
    unittest.main()

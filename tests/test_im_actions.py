import copy
import unittest
from dataclasses import replace

from active_agent.config import Settings
from active_agent.im import IMAgent, IMError
from active_agent.llm import ModelError
from tests.test_im import RoomService, Model


class ActionService(RoomService):
    def __init__(self):
        super().__init__()
        self.context.update({"context_hash": "test-context", "model": "test-model", "reasoning_effort": "medium",
            "actions": {"max_steps": 4, "operations": [{"name": "im_create_task", "arguments_schema": {
                "properties": {"title": {}, "assignee_id": {}}, "required": ["title", "assignee_id"]}}]}})
        self.plan, self.receipts = None, []
        self.plan_calls, self.execute_calls = [], []
        self.lose_plan_once, self.lose_operation_once, self.disconnect_second = False, False, False
        self.reject_second, self.pending_second = False, False
        self.business_writes = 0

    def request(self, method, path, body=None):
        if path.endswith("/claim"):
            if self.receipt:
                return {"turn": None}
            return {"turn": {"id": "turn-1", "lease_token": "lease-test", "action_plan": copy.deepcopy(self.plan),
                "action_receipts": copy.deepcopy(self.receipts)}, "context": copy.deepcopy(self.context)}
        if path.endswith("/plan"):
            self.plan_calls.append(copy.deepcopy(body))
            if not self.plan:
                self.plan = {"hash": "frozen-hash", "summary": body["summary"], "final_result": body["final_result"],
                    "steps": [{**s, "operation_id": "operation-"+str(i)} for i, s in enumerate(body["steps"])]}
            if self.lose_plan_once:
                self.lose_plan_once = False
                raise IMError(503, "connection_failed")
            return {"plan": copy.deepcopy(self.plan), "receipts": copy.deepcopy(self.receipts)}
        if path.endswith("/execute"):
            oid = path.split("/")[-2]
            self.execute_calls.append((path, copy.deepcopy(body)))
            if self.disconnect_second and oid == "operation-1":
                raise IMError(503, "connection_failed")
            existing = next((r for r in self.receipts if r["operation_id"] == oid), None)
            if not existing:
                status = "rejected" if self.reject_second and oid == "operation-1" else "applying" if self.pending_second and oid == "operation-1" else "committed"
                self.receipts.append({"operation_id": oid, "status": status})
                if status == "committed":
                    self.business_writes += 1
            if self.lose_operation_once:
                self.lose_operation_once = False
                raise IMError(503, "connection_failed")
            return {"plan": copy.deepcopy(self.plan), "receipts": copy.deepcopy(self.receipts)}
        return super().request(method, path, body)


def decision():
    return {"action": "reply", "content": "See verified receipts.", "rationale": "Visible assigned work", "summary": "Two concrete tasks", "steps": [
        {"key": "task-"+str(i), "operation": "im_create_task", "arguments": {"title": "Task "+str(i), "assignee_id": "agent-1"},
            "evidence": [{"kind": "message", "id": "m-1", "revision": 1, "quote": "Draft an acceptance spec"}]} for i in range(2)]}


class NativeActionWorkerTests(unittest.TestCase):
    def setUp(self):
        self.settings = replace(Settings(), model_name="test-model", model_reasoning_effort="medium", im_token="test-agent")

    def test_lost_plan_and_operation_responses_reuse_identical_ids_and_one_inference(self):
        service, model = ActionService(), Model(decision())
        service.lose_plan_once = service.lose_operation_once = True
        IMAgent(self.settings, service, model).cycle()
        self.assertEqual(len(model.calls), 1)
        self.assertEqual(service.plan_calls[0], service.plan_calls[1])
        self.assertEqual(service.execute_calls[0], service.execute_calls[1])
        self.assertEqual(service.business_writes, 2)
        self.assertNotIn("steps", service.finish_calls[0])

    def test_new_worker_resumes_only_uncommitted_steps_without_inference_or_new_plan(self):
        service, model = ActionService(), Model(decision())
        service.disconnect_second = True
        result = IMAgent(self.settings, service, model).cycle()
        self.assertEqual(result["results"][0]["state"], "awaiting_recovery")
        self.assertEqual(service.business_writes, 1)
        self.assertEqual(service.finish_calls, [])
        service.disconnect_second = False
        restarted_model = Model(ModelError("must not be called"))
        IMAgent(replace(self.settings, model_name="different-model"), service, restarted_model).cycle()
        self.assertEqual(restarted_model.calls, [])
        self.assertEqual(len(service.plan_calls), 1)
        self.assertEqual(service.business_writes, 2)
        self.assertEqual(service.finish_calls[0]["model"], "test-model")
        self.assertEqual(sum(path.endswith("operation-0/execute") for path, _ in service.execute_calls), 1)

    def test_rejected_action_stops_plan_and_never_claims_model_success(self):
        service = ActionService()
        service.reject_second = True
        IMAgent(self.settings, service, Model(decision())).cycle()
        self.assertEqual(service.finish_calls[0]["action"], "blocked")
        self.assertEqual(service.business_writes, 1)

    def test_pending_document_outcome_does_not_finish_or_switch_to_unscoped_tools(self):
        service = ActionService()
        service.pending_second = True
        result = IMAgent(self.settings, service, Model(decision())).cycle()
        self.assertEqual(result["results"][0]["state"], "awaiting_recovery")
        self.assertEqual(service.finish_calls, [])

    def test_unadvertised_or_unbounded_actions_are_rejected_before_any_plan(self):
        for modify in [lambda v: v["steps"][0].update(operation="office_send_mail"),
            lambda v: v["steps"][0]["arguments"].update(token="untrusted-secret"),
            lambda v: v.update(steps=v["steps"]*3),
            lambda v: v["steps"][0].update(evidence=[])]:
            service, value = ActionService(), decision()
            modify(value)
            IMAgent(self.settings, service, Model(value)).cycle()
            self.assertEqual(service.plan_calls, [])
            self.assertEqual(service.business_writes, 0)
            self.assertEqual(service.finish_calls[0]["action"], "blocked")
            self.assertNotIn("untrusted-secret", str(service.finish_calls))


if __name__ == "__main__":
    unittest.main()

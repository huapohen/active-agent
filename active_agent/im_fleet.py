"""Local supervisor: agent-store installations become independently logged-in peers.

Only this supervisor receives the administrative provisioning credential. Each
participant's requests carry its own derived bearer; credentials are never logged
or saved here. This is a bounded local worker host, not a distributed orchestrator.
"""
from dataclasses import replace
import logging
import threading

from .im import IMAgent, IMClient, IMError
from .llm import ModelError

logger = logging.getLogger(__name__)


class LimitedModel:
    def __init__(self, model, slots):
        self.model, self.slots = model, slots

    def complete_json(self, system, user):
        if not self.slots.acquire(timeout=15):
            raise ModelError("local worker capacity reached")
        try:
            return self.model.complete_json(system, user)
        finally:
            self.slots.release()


class OfficeFleet:
    def __init__(self, settings, client=None, factory=IMAgent):
        if not settings.im_admin_token:
            raise ValueError("AA_IM_ADMIN_TOKEN is required by the local supervisor")
        self.settings = settings
        self.client = client or IMClient(settings.doc_free_url, settings.im_admin_token)
        self.factory, self.workers = factory, {}
        self.worker_tokens = {}
        self.slots = threading.BoundedSemaphore(min(settings.im_model_concurrency, settings.im_worker_slots))

    def sync(self):
        registry = self.client.request("GET", "/admin/workers")["workers"]
        desired = {entry["principal"]["id"]: entry["token"] for entry in registry
            if entry.get("runnable_room_count", 1) > 0}
        if self.settings.im_token and self.settings.im_token not in desired.values():
            desired["local-primary"] = self.settings.im_token
        # One bounded thread per eligible installed identity, no process per catalog entry.
        # Legacy servers omit runnable_room_count; their workers remain long-poll idle.
        desired = dict(list(desired.items())[:self.settings.im_worker_slots])
        for pid in list(self.workers):
            thread, stop = self.workers[pid]
            if pid not in desired or not thread.is_alive() or self.worker_tokens.get(pid) != desired[pid]:
                stop.set()
                del self.workers[pid]
                self.worker_tokens.pop(pid, None)
        for pid, token in desired.items():
            if pid in self.workers:
                continue
            agent = self.factory(replace(self.settings, im_token=token,
                im_admin_token="", doc_free_token=""))
            if agent.model:
                agent.model = LimitedModel(agent.model, self.slots)
            stop = threading.Event()

            def work(current=agent, signal=stop):
                try:
                    current.run(signal)
                except (IMError, ValueError):
                    logger.warning("A native colleague stopped; registry will reconcile")

            thread = threading.Thread(target=work, name="office-participant", daemon=True)
            self.workers[pid] = (thread, stop)
            self.worker_tokens[pid] = token
            thread.start()
        return len(self.workers)

    def run(self, stop=None):
        stop = stop or threading.Event()
        logger.info("Native office host online; installed colleagues use independent identities")
        try:
            while not stop.is_set():
                try:
                    self.sync()
                except IMError as exc:
                    logger.warning("Office registry unavailable: HTTP %s", exc.status)
                stop.wait(5)
        finally:
            for _, signal in self.workers.values():
                signal.set()

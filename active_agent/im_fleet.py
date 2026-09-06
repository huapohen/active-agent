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
        self.slots = threading.BoundedSemaphore(3)

    def sync(self):
        registry = self.client.request("GET", "/admin/workers")["workers"]
        desired = {entry["principal"]["id"]: entry["token"] for entry in registry}
        if self.settings.im_token:
            desired["local-primary"] = self.settings.im_token
        # Eight local identities are enough for the preview. The store itself is
        # durable; installations outside this host's capacity remain visibly idle.
        desired = dict(list(desired.items())[:8])
        for pid in list(self.workers):
            thread, stop = self.workers[pid]
            if pid not in desired or not thread.is_alive():
                stop.set()
                del self.workers[pid]
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

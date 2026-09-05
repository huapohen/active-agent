import logging
import threading
from typing import Optional

from .adapters.base import DeliveryAdapter
from .engine import ActiveAgent


logger = logging.getLogger(__name__)


class Runtime:
    def __init__(self, agent: ActiveAgent, tick_seconds: int, delivery: Optional[DeliveryAdapter] = None):
        self.agent = agent
        self.tick_seconds = tick_seconds
        self.delivery = delivery
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._loop, name="active-agent-runtime", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=self.tick_seconds + 1)

    def tick(self) -> None:
        self.agent.run_cycle()
        if not self.delivery:
            return
        for item in self.agent.store.pending_outbox():
            try:
                self.delivery.send(item)
                self.agent.store.mark_delivered(item["outbox_id"])
            except Exception as exc:  # adapters own retries; keep item pending
                logger.warning("outbox delivery failed: %s", exc.__class__.__name__)

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                self.tick()
            except Exception as exc:
                logger.exception("active agent cycle failed: %s", exc.__class__.__name__)
            self._stop.wait(self.tick_seconds)


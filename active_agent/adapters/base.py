from typing import Any, Dict, Protocol


class DeliveryAdapter(Protocol):
    """Implement this once per IM. Ingestion stays on the stable HTTP event contract."""

    def send(self, message: Dict[str, Any]) -> None: ...


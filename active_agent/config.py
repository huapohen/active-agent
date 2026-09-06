from dataclasses import dataclass
import os
from pathlib import Path
import stat


def _load_local_env(path: Path = Path(".env")) -> None:
    """Load the local ignored env file without adding a runtime dependency."""
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def save_model_key(secret: str, path: Path = Path(".env")) -> None:
    """Persist a key without putting it in argv or stdout."""
    if not secret or "\n" in secret or "\r" in secret:
        raise ValueError("model key must be a non-empty single line")
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    replacement = "AA_MODEL_API_KEY=" + secret
    for index, line in enumerate(lines):
        if line.startswith("AA_MODEL_API_KEY="):
            lines[index] = replacement
            break
    else:
        lines.append(replacement)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
    temporary.chmod(stat.S_IRUSR | stat.S_IWUSR)
    temporary.replace(path)


@dataclass(frozen=True)
class Settings:
    db_path: Path = Path("data/active_agent.db")
    agent_name: str = "AA"
    mention: str = "@AA"
    api_token: str = ""
    model_api_key: str = ""
    model_base_url: str = "https://api.deepseek.com"
    model_name: str = "deepseek-chat"
    model_reasoning_effort: str = "medium"
    model_api_style: str = "chat"
    model_timeout: int = 90
    doc_free_url: str = "http://127.0.0.1:3210"
    doc_free_token: str = ""
    im_token: str = ""
    im_admin_token: str = ""
    im_wait_seconds: int = 20
    document_poll_seconds: int = 2
    tick_seconds: int = 30
    min_silence_seconds: int = 300

    @classmethod
    def from_env(cls) -> "Settings":
        _load_local_env()
        return cls(
            db_path=Path(os.getenv("AA_DB_PATH", "data/active_agent.db")),
            agent_name=os.getenv("AA_NAME", "AA"),
            mention=os.getenv("AA_MENTION", "@AA"),
            api_token=os.getenv("AA_API_TOKEN", ""),
            model_api_key=os.getenv("AA_MODEL_API_KEY", ""),
            model_base_url=os.getenv("AA_MODEL_BASE_URL", "https://api.deepseek.com"),
            model_name=os.getenv("AA_MODEL_NAME", "deepseek-chat"),
            model_reasoning_effort=os.getenv("AA_MODEL_REASONING_EFFORT", "medium"),
            model_api_style=os.getenv("AA_MODEL_API_STYLE", "chat"),
            model_timeout=max(5, min(300, int(os.getenv("AA_MODEL_TIMEOUT", "90")))),
            doc_free_url=os.getenv("AA_DOC_FREE_URL", "http://127.0.0.1:3210").rstrip("/"),
            doc_free_token=os.getenv("AA_DOC_FREE_TOKEN", ""),
            im_token=os.getenv("AA_IM_TOKEN", ""),
            im_admin_token=os.getenv("AA_IM_ADMIN_TOKEN", ""),
            im_wait_seconds=max(1, min(25, int(os.getenv("AA_IM_WAIT_SECONDS", "20")))),
            document_poll_seconds=max(1, int(os.getenv("AA_DOCUMENT_POLL_SECONDS", "2"))),
            tick_seconds=max(5, int(os.getenv("AA_TICK_SECONDS", "30"))),
            min_silence_seconds=max(0, int(os.getenv("AA_MIN_SILENCE_SECONDS", "300"))),
        )

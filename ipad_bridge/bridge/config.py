from __future__ import annotations

import json
import secrets
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Settings:
    data_dir: Path
    backend: str = "mock"
    comfy_url: str = "http://127.0.0.1:8188"
    poll_seconds: float = 1.0
    job_timeout_seconds: float = 3600
    recovery_seconds: float = 90
    start_worker: bool = True
    preset_dir: Path | None = None
    enable_experimental: bool = False
    comfy_models_dir: Path | None = None
    comfy_install_dir: Path | None = None
    max_pending_jobs: int = 8
    max_pending_bytes: int = 256 * 1024 * 1024

    def __post_init__(self):
        self.data_dir = Path(self.data_dir).resolve()
        if self.backend not in {"mock", "comfyui"}:
            raise ValueError("backend must be mock or comfyui")
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.preset_dir = Path(self.preset_dir or Path(__file__).parent / "presets").resolve()
        for name in ("comfy_models_dir", "comfy_install_dir"):
            value = getattr(self, name)
            if value is not None:
                setattr(self, name, Path(value).resolve())
        if type(self.max_pending_jobs) is not int or self.max_pending_jobs < 1:
            raise ValueError("max_pending_jobs must be a positive integer")
        if type(self.max_pending_bytes) is not int or self.max_pending_bytes < 1:
            raise ValueError("max_pending_bytes must be a positive integer")

    @property
    def preset_id(self) -> str:
        return "mock-paint-v1" if self.backend == "mock" else "paint-edit-v1"

    def token(self) -> str:
        path = self.data_dir / "access-token.txt"
        try:
            with path.open("x", encoding="utf-8") as handle:
                handle.write(secrets.token_urlsafe(32))
            try:
                path.chmod(0o600)
            except OSError:
                pass
        except FileExistsError:
            pass
        token = path.read_text(encoding="utf-8").strip()
        if len(token) < 32:
            raise ValueError("The access token must contain at least 32 characters")
        return token

    def write_pairing(self, base_url: str) -> Path:
        from urllib.parse import urlsplit

        parsed = urlsplit(base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username:
            raise ValueError("base URL must be an HTTP(S) origin")
        if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
            raise ValueError("base URL must not contain a path, query or fragment")
        path = self.data_dir / "pairing.json"
        path.write_text(json.dumps({
            "protocolVersion": 1,
            "baseUrl": base_url.rstrip("/"),
            "accessToken": self.token(),
            "backend": self.backend,
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return path

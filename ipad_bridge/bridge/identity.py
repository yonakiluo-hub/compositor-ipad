"""Private local dependency evidence. Only digests and relative model names leave it."""
from __future__ import annotations

import hashlib
import json
import threading
from pathlib import Path


class IdentityError(ValueError):
    pass


def digest_json(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


class DependencyIdentity:
    def __init__(self, models_dir: Path | None, install_dir: Path | None):
        self.models_dir = models_dir
        self.install_dir = install_dir
        self._cache = {}
        self._lock = threading.Lock()

    def _hash(self, path: Path, not_newer_than: float | None = None) -> str:
        before = path.stat()
        if not_newer_than is not None and max(before.st_mtime, before.st_ctime) > not_newer_than:
            raise IdentityError("A dependency changed after ComfyUI started. Restart ComfyUI before accepting new tasks.")
        key = (str(path), before.st_size, before.st_mtime_ns, before.st_ctime_ns)
        with self._lock:
            cached = self._cache.get(key)
            if cached:
                return cached
            with path.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            after = path.stat()
            if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise IdentityError("A dependency changed while it was being fingerprinted. Retry after installation finishes.")
            self._cache[key] = digest
            return digest

    def capture(self, dependencies: list[dict], not_newer_than: float | None = None) -> dict:
        if self.models_dir is None or self.install_dir is None:
            raise IdentityError("Configure the local ComfyUI model and installation directories before accepting new GPU jobs.")
        try:
            root = self.models_dir.resolve(strict=True)
            install = self.install_dir.resolve(strict=True)
            weights = []
            for item in dependencies:
                category, filename = item["category"], item["filename"]
                if not isinstance(filename, str) or any(char in filename for char in ("/", "\\", ":")):
                    raise IdentityError("Model names must stay inside the configured model directory.")
                aliases = {"diffusion_models": "unet", "text_encoders": "clip"}
                if category in aliases and (root / aliases[category] / filename).exists():
                    raise IdentityError("An alternate legacy model directory contains the same model name. Resolve the ambiguity before accepting new tasks.")
                path = (root / category / filename).resolve(strict=True)
                if not path.is_relative_to(root) or not path.is_file():
                    raise IdentityError("A required model is unavailable inside the configured model directory.")
                if not_newer_than is not None and max(path.stat().st_mtime, path.stat().st_ctime) > not_newer_than:
                    raise IdentityError("A model changed after ComfyUI started. Restart ComfyUI before accepting new tasks.")
                digest = self._hash(path, not_newer_than)
                if item.get("sha256") and digest != item["sha256"]:
                    raise IdentityError("A model does not match the preset's pinned digest.")
                weights.append({"category": category, "filename": filename, "sha256": digest, "bytes": path.stat().st_size})
            # Built-in nodes only. Custom nodes are deliberately not admitted by this runtime.
            files = list(install.glob("*.py"))
            for directory in ("comfy", "comfy_extras", "comfy_api", "comfy_execution"):
                files.extend((install / directory).rglob("*.py"))
            if not (install / "main.py").is_file() or not files:
                raise IdentityError("The configured ComfyUI source installation is unavailable.")
            sources = []
            for path in sorted(files):
                resolved = path.resolve(strict=True)
                if not resolved.is_relative_to(install):
                    raise IdentityError("ComfyUI source files must remain inside the configured installation.")
                if not_newer_than is not None and max(resolved.stat().st_mtime, resolved.stat().st_ctime) > not_newer_than:
                    raise IdentityError("ComfyUI source changed after startup. Restart ComfyUI before accepting new tasks.")
                sources.append([path.relative_to(install).as_posix(), self._hash(resolved, not_newer_than)])
            return {"weights": weights, "sourceSha256": digest_json(sources), "sourceFileCount": len(sources)}
        except (OSError, KeyError, TypeError):
            raise IdentityError("A required local model or ComfyUI source dependency is missing or unreadable.") from None

"""ComfyUI HTTP adapter for the fixed, local paint-edit preset.

The model edits the supplied crop as a reference image. It does NOT see the mask.
After download, the bridge worker must apply the original mask as result alpha.
No HTTP operation here retries a submission or interrupts the shared GPU queue.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path, PurePosixPath
from typing import Any

import httpx


class ComfyError(RuntimeError):
    """A short public-safe error; submit_unknown needs recovery, not resubmission."""

    def __init__(self, message: str, code: str = "comfy_error", retryable: bool = False):
        super().__init__(message)
        self.code = code
        self.retryable = retryable


class ComfyBackend:
    def __init__(self, base_url: str, preset_dir: Path, timeout: float = 60.0):
        self.preset_dir = Path(preset_dir)
        # Local GPU calls must not be redirected by a machine's HTTP proxy settings.
        self.client = httpx.AsyncClient(
            base_url=base_url.rstrip("/") + "/", timeout=timeout,
            trust_env=False, follow_redirects=False,
        )

    async def close(self) -> None:
        await self.client.aclose()

    async def __aenter__(self) -> "ComfyBackend":
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.close()

    def _preset(self, preset_id: str) -> tuple[dict, dict]:
        manifest = json.loads((self.preset_dir / "manifest.json").read_text("utf-8"))
        entry = next((p for p in manifest["presets"] if p["id"] == preset_id), None)
        if entry is None:
            raise ComfyError("Unknown workflow preset.", "unknown_preset")
        path = (self.preset_dir / entry["graph"]).resolve()
        if not path.is_relative_to(self.preset_dir.resolve()):
            raise ComfyError("Invalid server preset configuration.", "invalid_preset")
        return entry, json.loads(path.read_text("utf-8"))

    async def _json(self, method: str, route: str, *, submitting: bool = False, **kwargs: Any) -> dict:
        try:
            response = await self.client.request(method, route.lstrip("/"), **kwargs)
        except httpx.RequestError as error:
            code = "submit_unknown" if submitting else "comfy_unavailable"
            raise ComfyError(
                "ComfyUI submission outcome is unknown; recover the existing job before retrying."
                if submitting else "ComfyUI is unreachable or timed out.", code, True,
            ) from error
        if response.status_code >= 500:
            raise ComfyError("ComfyUI returned a server error.", "submit_unknown" if submitting else "comfy_unavailable", True)
        if not response.is_success:
            # Do not return upstream traces, filesystem paths or input text to clients.
            raise ComfyError(
                f"ComfyUI rejected the request (HTTP {response.status_code}). Check the preset nodes and models.",
                "prompt_rejected" if submitting else "comfy_request_rejected",
            )
        try:
            result = response.json()
            if not isinstance(result, dict):
                raise ValueError("Expected JSON object")
            return result
        except (ValueError, UnicodeError) as error:
            raise ComfyError("ComfyUI returned an invalid response.", "submit_unknown" if submitting else "comfy_invalid_response", submitting) from error

    @staticmethod
    def _job_id(job_id: str) -> str:
        if not isinstance(job_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", job_id):
            raise ComfyError("Invalid bridge job ID.", "invalid_job")
        return job_id

    async def preflight(self, preset_id: str) -> dict:
        """Compare the fixed API graph against live node and model dropdown schemas."""
        entry, graph = self._preset(preset_id)
        info = await self._json("GET", "/object_info")
        missing_nodes: set[str] = set()
        missing_models: set[str] = set()
        invalid: list[str] = []
        for node_id, node in graph.items():
            kind = node["class_type"]
            if kind not in info:
                missing_nodes.add(kind)
                continue
            schema = info[kind].get("input", {})
            required = schema.get("required", {})
            allowed = {**required, **schema.get("optional", {})}
            values = node["inputs"]
            invalid.extend(f"{kind}.{key}: missing" for key in required if key not in values)
            for key, value in values.items():
                if key not in allowed:
                    invalid.append(f"{kind}.{key}: unsupported")
                    continue
                spec = allowed[key]
                if isinstance(value, list):
                    if len(value) != 2 or value[0] not in graph or not isinstance(value[1], int) or value[1] < 0:
                        invalid.append(f"{node_id}.{key}: invalid link")
                    continue
                if kind == "LoadImage" and key == "image":
                    continue  # This job's unique input file is uploaded after preflight.
                options = spec[0] if isinstance(spec[0], list) else (spec[1].get("options") if len(spec) > 1 and isinstance(spec[1], dict) else None)
                if options is not None and value not in options:
                    if key in ("unet_name", "clip_name", "vae_name"):
                        missing_models.add(str(value))
                    else:
                        invalid.append(f"{kind}.{key}: unsupported value")
        return {
            "ok": not (missing_nodes or missing_models or invalid),
            "presetId": preset_id, "technique": entry["technique"],
            "missingNodes": sorted(missing_nodes), "missingModels": sorted(missing_models),
            "invalidInputs": invalid,
        }

    async def prepare(self, image_path: Path, mask_path: Path, metadata: dict, job_id: str) -> dict:
        """Upload a crop and return a fresh API graph; mask is enforced by the worker."""
        self._job_id(job_id)
        preset_id = metadata.get("workflowPreset", "paint-edit-v1")
        entry, graph = self._preset(preset_id)
        prompt = metadata.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4000:
            raise ComfyError("The edit prompt must contain 1 to 4000 characters.", "invalid_prompt")
        seed = metadata.get("seed", int.from_bytes(hashlib.sha256(job_id.encode()).digest()[:8], "big"))
        if isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed <= 0xFFFFFFFFFFFFFFFF:
            raise ComfyError("Seed must be an unsigned 64-bit integer.", "invalid_seed")
        if "inputSize" in metadata:
            size = metadata["inputSize"]
            width, height = size.get("width"), size.get("height")
            if (type(width) is not int or type(height) is not int or min(width, height) < 16
                    or max(width, height) > 16 * min(width, height)):
                raise ComfyError(
                    "Expand the crop to at least 16 pixels on each side and an aspect ratio of 16:1 or less.",
                    "invalid_crop",
                )
        if not Path(image_path).is_file() or not Path(mask_path).is_file():
            raise ComfyError("The saved image or mask is missing.", "missing_input")
        status = await self.preflight(preset_id)
        if not status["ok"]:
            details = status["missingNodes"] + status["missingModels"] + status["invalidInputs"]
            raise ComfyError("ComfyUI preset requirements are missing: " + ", ".join(details), "preset_unavailable")
        with Path(image_path).open("rb") as stream:
            upload = await self._json(
                "POST", "/upload/image", files={"image": ("source.png", stream, "image/png")},
                data={"type": "input", "subfolder": f"ipad_bridge/{job_id}", "overwrite": "true"},
            )
        descriptor = self._descriptor(upload, expected_type="input")
        image_name = str(PurePosixPath(descriptor["subfolder"]) / descriptor["filename"])
        bindings = entry["bindings"]
        for role, value in {
            "image": image_name, "prompt": prompt, "seed": seed,
            "outputPrefix": f"iPadBridge/{job_id}/candidate",
        }.items():
            binding = bindings[role]
            graph[binding["node"]]["inputs"][binding["input"]] = value
        return graph

    async def submit(self, graph: dict, job_id: str) -> str:
        self._job_id(job_id)
        result = await self._json("POST", "/prompt", submitting=True, json={
            "prompt": graph, "client_id": f"ipad-bridge-{job_id}",
            "extra_data": {"bridge_job_id": job_id, "bridge_protocol": 1},
        })
        prompt_id = result.get("prompt_id")
        if not isinstance(prompt_id, str) or not prompt_id or "/" in prompt_id:
            raise ComfyError("ComfyUI did not confirm its prompt ID; recover before retrying.", "submit_unknown", True)
        return prompt_id

    @staticmethod
    def _queue_items(queue: dict) -> list:
        return queue.get("queue_running", []) + queue.get("queue_pending", [])

    @staticmethod
    def _matches(item: Any, job_id: str) -> str | None:
        if isinstance(item, (list, tuple)) and len(item) >= 4 and isinstance(item[3], dict):
            if item[3].get("bridge_job_id") == job_id and isinstance(item[1], str):
                return item[1]
        return None

    async def find_job(self, job_id: str) -> str | None:
        """Recover a submission whose local prompt ID write was interrupted.

        None means absent from current queue/history, not proof it never executed:
        ComfyUI history can be cleared or lost on a ComfyUI process restart.
        """
        self._job_id(job_id)
        queue = await self._json("GET", "/queue")
        history = await self._json("GET", "/history")
        matches = {p for item in self._queue_items(queue) if (p := self._matches(item, job_id))}
        matches.update(p for entry in history.values() if isinstance(entry, dict) and (p := self._matches(entry.get("prompt"), job_id)))
        if len(matches) > 1:
            raise ComfyError("More than one ComfyUI prompt matches this bridge job; manual review is required.", "recovery_ambiguous")
        return next(iter(matches), None)

    @staticmethod
    def _descriptor(value: dict, expected_type: str = "output") -> dict:
        filename = value.get("filename", value.get("name"))
        subfolder = value.get("subfolder", "")
        kind = value.get("type", expected_type)
        if not isinstance(filename, str) or not filename or any(c in filename for c in "/\\:\x00") or filename in (".", ".."):
            raise ComfyError("ComfyUI returned an invalid image filename.", "comfy_invalid_response")
        if not isinstance(subfolder, str):
            raise ComfyError("ComfyUI returned an invalid image directory.", "comfy_invalid_response")
        # Windows SaveImage returns os.path subfolders with backslashes. Convert
        # separators BEFORE checking absoluteness and traversal, so UNC paths,
        # rooted Windows paths and mixed-separator '..' cannot bypass checks.
        normalized = subfolder.replace("\\", "/")
        directory = PurePosixPath(normalized)
        if ":" in normalized or "\x00" in normalized or directory.is_absolute() or ".." in directory.parts:
            raise ComfyError("ComfyUI returned an invalid image directory.", "comfy_invalid_response")
        subfolder = str(directory) if normalized else ""
        if kind != expected_type:
            raise ComfyError("ComfyUI returned an unexpected image type.", "comfy_invalid_response")
        return {"filename": filename, "subfolder": subfolder, "type": kind}

    def _history_state(self, entry: dict) -> dict:
        status = entry.get("status") or {}
        messages = status.get("messages", [])
        errors = [m for m in messages if isinstance(m, (list, tuple)) and m and m[0] in ("execution_error", "execution_interrupted")]
        if status.get("status_str") == "error" or errors:
            reason = "ComfyUI generation was interrupted." if any(m[0] == "execution_interrupted" for m in errors) else "ComfyUI generation failed; inspect the Windows ComfyUI log."
            return {"state": "failed", "outputs": [], "error": reason}
        if not status.get("completed"):
            return {"state": "failed", "outputs": [], "error": "ComfyUI recorded an incomplete execution."}
        outputs = []
        for node in entry.get("outputs", {}).values():
            for descriptor in node.get("images", []):
                if descriptor.get("type") == "output":
                    outputs.append(self._descriptor(descriptor))
        if not outputs:
            return {"state": "failed", "outputs": [], "error": "ComfyUI completed without a saved output image."}
        return {"state": "succeeded", "outputs": outputs}

    async def inspect(self, prompt_id: str) -> dict:
        if not isinstance(prompt_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", prompt_id):
            raise ComfyError("Invalid ComfyUI prompt ID.", "invalid_prompt_id")
        history = await self._json("GET", f"/history/{prompt_id}")
        if prompt_id in history:
            return self._history_state(history[prompt_id])
        queue = await self._json("GET", "/queue")
        if any(isinstance(item, (list, tuple)) and len(item) > 1 and item[1] == prompt_id for item in self._queue_items(queue)):
            return {"state": "running", "outputs": []}
        # It may have moved from queue to history between the previous two reads.
        history = await self._json("GET", f"/history/{prompt_id}")
        if prompt_id in history:
            return self._history_state(history[prompt_id])
        return {"state": "missing", "outputs": []}

    async def download(self, output: dict) -> bytes:
        descriptor = self._descriptor(output)
        try:
            response = await self.client.get("view", params=descriptor)
        except httpx.RequestError as error:
            raise ComfyError("ComfyUI result download timed out or disconnected.", "comfy_unavailable", True) from error
        if not response.is_success:
            raise ComfyError(f"ComfyUI result download failed (HTTP {response.status_code}).", "download_failed", response.status_code >= 500)
        return response.content

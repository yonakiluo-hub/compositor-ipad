"""ComfyUI HTTP adapter for the fixed, local paint-edit preset.

The model edits the supplied crop as a reference image. It does NOT see the mask.
After download, the bridge worker must apply the original mask as result alpha.
No HTTP operation here retries a submission or interrupts the shared GPU queue.
"""
from __future__ import annotations

import hashlib
import asyncio
import copy
import json
import re
from pathlib import Path, PurePosixPath
from typing import Any

import httpx

from .registry import PresetRegistry, RegistryError
from .identity import DependencyIdentity, IdentityError, digest_json
from .local_runtime import attest_local_runtime, LocalRuntimeError


class ComfyError(RuntimeError):
    """A short public-safe error; submit_unknown needs recovery, not resubmission."""

    def __init__(self, message: str, code: str = "comfy_error", retryable: bool = False):
        super().__init__(message)
        self.code = code
        self.retryable = retryable


class ComfyBackend:
    def __init__(self, base_url: str, preset_dir: Path, timeout: float = 60.0, *, registry=None, models_dir=None, install_dir=None):
        self.preset_dir = Path(preset_dir)
        self.base_url = base_url
        self.registry = registry or PresetRegistry(preset_dir)
        self.identity = DependencyIdentity(models_dir, install_dir)
        self._freeze_lock = asyncio.Lock()
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
        try:
            return self.registry.load(preset_id)
        except RegistryError as exc:
            raise ComfyError(str(exc), exc.code) from None

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

    @staticmethod
    def _expanded_inputs(schema: dict) -> tuple[dict, dict]:
        """Expand bounded core autogrow templates exactly as ComfyUI's V3 schema.

        A container such as ``images`` is not itself an API input. Only named
        children advertised by the core schema are accepted; arbitrary dotted
        fields are never treated as optional or ignored.
        """
        required = dict(schema.get("required", {}))
        optional = dict(schema.get("optional", {}))
        for group in (required, optional):
            for key, spec in list(group.items()):
                if not isinstance(spec, (list, tuple)) or not spec:
                    raise ValueError("Invalid input schema")
                if spec[0] != "COMFY_AUTOGROW_V3":
                    continue
                if len(spec) != 2 or not isinstance(spec[1], dict):
                    raise ValueError("Invalid autogrow schema")
                template = spec[1].get("template")
                if not isinstance(template, dict):
                    raise ValueError("Missing autogrow template")
                minimum = template.get("min")
                if type(minimum) is not int or minimum < 0:
                    raise ValueError("Invalid autogrow minimum")
                if "names" in template and "prefix" not in template:
                    names = template["names"]
                elif "prefix" in template and "names" not in template:
                    maximum = template.get("max")
                    prefix = template["prefix"]
                    if type(maximum) is not int or not 1 <= maximum <= 100 or not isinstance(prefix, str):
                        raise ValueError("Invalid autogrow prefix")
                    names = [f"{prefix}{index}" for index in range(maximum)]
                else:
                    raise ValueError("Unknown autogrow template")
                if (not isinstance(names, list) or not 1 <= len(names) <= 100 or minimum > len(names)
                        or any(not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", name) for name in names)
                        or len(set(names)) != len(names)):
                    raise ValueError("Invalid autogrow names")
                inputs = template.get("input")
                if not isinstance(inputs, dict):
                    raise ValueError("Invalid autogrow input")
                candidates = [(section, child) for section, children in inputs.items()
                              if section in {"required", "optional"} and isinstance(children, dict)
                              for child in children.values()]
                if len(candidates) != 1:
                    raise ValueError("Unsupported autogrow input count")
                child_section, child_spec = candidates[0]
                if (not isinstance(child_spec, (list, tuple)) or not child_spec
                        or child_spec[0] == "COMFY_AUTOGROW_V3"):
                    raise ValueError("Invalid nested autogrow input")
                del group[key]
                for index, name in enumerate(names):
                    child = f"{key}.{name}"
                    if child in required or child in optional:
                        raise ValueError("Conflicting autogrow child")
                    target = required if child_section == "required" and index < minimum else optional
                    target[child] = child_spec
        return required, {**required, **optional}

    async def preflight(self, preset_id: str, snapshot: dict | None = None) -> dict:
        """Compare the fixed API graph against live node and model dropdown schemas."""
        if snapshot:
            entry, graph = snapshot, snapshot["graph"]
        else:
            try:
                entry, graph = self.registry.load(preset_id, allow_disabled=True)
            except RegistryError as exc:
                raise ComfyError(str(exc), exc.code) from None
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
            try:
                required, allowed = self._expanded_inputs(schema)
            except (ValueError, TypeError):
                invalid.append(f"{kind}: unsupported input schema")
                continue
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
                    if key in ("unet_name", "clip_name", "vae_name", "lora_name", "ckpt_name"):
                        missing_models.add(str(value))
                    else:
                        invalid.append(f"{kind}.{key}: unsupported value")
        return {
            "ok": not (missing_nodes or missing_models or invalid),
            "presetId": preset_id, "technique": entry.get("technique", "reference_edit_with_output_mask"),
            "installed": not (missing_nodes or missing_models),
            "structuralPreflight": not (missing_nodes or missing_models or invalid),
            "gpuSmoke": "unverified", "qualityAdmission": "pending",
            "missingNodes": sorted(missing_nodes), "missingModels": sorted(missing_models),
            "invalidInputs": invalid,
        }

    async def _runtime_identity(self, snapshot: dict) -> dict:
        stats = await self._json("GET", "/system_stats")
        system = stats.get("system", {})
        self._verify_local_runtime(system)
        try:
            instance = await asyncio.to_thread(attest_local_runtime, self.base_url, system["argv"])
            local = await asyncio.to_thread(self.identity.capture, snapshot["dependencies"], instance["startedAt"])
            if await asyncio.to_thread(attest_local_runtime, self.base_url, system["argv"]) != instance:
                raise LocalRuntimeError("ComfyUI restarted during dependency verification. Retry the same request.")
        except (IdentityError, LocalRuntimeError) as exc:
            raise ComfyError(str(exc), "dependency_identity_unavailable") from None
        versions = {key: system.get(key) for key in ("comfyui_version", "pytorch_version", "python_version")}
        if not all(isinstance(value, str) and value for value in versions.values()):
            raise ComfyError("ComfyUI did not report its runtime versions.", "runtime_identity_unavailable")
        packages = system.get("comfy_package_versions", [])
        if (not isinstance(packages, list) or not packages
                or any(not isinstance(item, dict) or any(not isinstance(item.get(key), str) or not item[key] for key in ("name", "installed"))
                       or (item.get("required") is not None and not isinstance(item["required"], str)) for item in packages)
                or len({item["name"] for item in packages}) != len(packages)):
            raise ComfyError("ComfyUI did not report its package versions.", "runtime_identity_unavailable")
        versions["packages"] = sorted([{key: item.get(key) for key in ("name", "installed", "required")} for item in packages], key=lambda item: item["name"])
        operational = {"--listen", "--port", "--models-directory", "--input-directory", "--output-directory", "--temp-directory", "--user-directory", "--database-url"}
        options = []
        args = iter(system["argv"][1:])
        for arg in args:
            if arg in operational:
                next(args, None)
            else:
                options.append(arg)
        return {**local, "versions": versions, "executionOptions": options}

    def _verify_local_runtime(self, system: dict) -> None:
        """Bind local file hashes to the actual controlled server, not a same-version neighbour."""
        argv = system.get("argv")
        install, models = self.identity.install_dir, self.identity.models_dir
        try:
            if not install or not models or not isinstance(argv, list) or not all(isinstance(arg, str) for arg in argv):
                raise ValueError()
            if Path(argv[0]).resolve() != (install / "main.py").resolve():
                raise ValueError()
            if sum(arg.split("=", 1)[0] == "--models-directory" for arg in argv) != 1 or Path(argv[argv.index("--models-directory") + 1]).resolve() != models.resolve():
                raise ValueError()
            if not {"--disable-all-custom-nodes", "--disable-api-nodes"} <= set(argv):
                raise ValueError()
            forbidden = ("--extra-model-paths-config", "--base-directory", "--enable-custom-nodes", "--whitelist-custom-nodes")
            if any(arg.split("=", 1)[0] in forbidden for arg in argv) or (install / "extra_model_paths.yaml").exists():
                raise ValueError()
            # Only canonical controlled-launch options are accepted. argparse accepts
            # abbreviations and repeated flags that could otherwise override a root.
            supported = {"--listen", "--port", "--models-directory", "--input-directory", "--output-directory",
                         "--temp-directory", "--user-directory", "--database-url", "--disable-auto-launch",
                         "--disable-all-custom-nodes", "--disable-api-nodes", "--lowvram", "--normalvram",
                         "--disable-smart-memory", "--cache-none", "--reserve-vram", "--cuda-device",
                         "--use-pytorch-cross-attention"}
            if any(arg not in supported for arg in argv[1:] if arg.startswith("--")):
                raise ValueError()
        except (ValueError, IndexError, OSError):
            raise ComfyError("The running ComfyUI must match the configured source and model roots with custom/API nodes disabled and no extra model paths.", "runtime_configuration_mismatch") from None

    async def freeze(self, metadata: dict) -> dict:
        """Capture accepted graph, fixed parameters, exact weights and runtime before enqueue."""
        async with self._freeze_lock:
            try:
                snapshot = self.registry.freeze(metadata["workflowPreset"], metadata)
            except RegistryError as exc:
                raise ComfyError(str(exc), exc.code) from None
            limits = snapshot["limits"]
            width, height = metadata["inputSize"]["width"], metadata["inputSize"]["height"]
            if (width * height > limits["maxInputPixels"] or min(width, height) < limits["minimumInputSide"]
                    or max(width, height) > limits["maximumAspectRatio"] * min(width, height)):
                raise ComfyError("The crop exceeds this preset's supported size or aspect ratio. Adjust the crop explicitly.", "invalid_crop")
            status = await self.preflight(snapshot["presetId"], snapshot)
            if not status["ok"]:
                raise ComfyError("The selected preset is missing compatible nodes, models or inputs. Check its backend status.", "preset_unavailable")
            snapshot["runtime"] = await self._runtime_identity(snapshot)
            snapshot["executionContractVersion"] = 1
            snapshot["comfyOrigin"] = self.base_url.rstrip("/")
            snapshot["dependencyFingerprint"] = digest_json(snapshot["runtime"])
            return snapshot

    async def prepare(self, image_path: Path, mask_path: Path, metadata: dict, job_id: str, snapshot: dict | None = None) -> dict:
        """Upload a crop and return a fresh API graph; mask is enforced by the worker."""
        self._job_id(job_id)
        preset_id = metadata.get("workflowPreset", "paint-edit-v1")
        entry, graph = (snapshot, copy.deepcopy(snapshot["graph"])) if snapshot else self._preset(preset_id)
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
        if snapshot:
            if snapshot["presetId"] != preset_id or snapshot["parameters"] != {"prompt": prompt, "seed": seed} or digest_json(graph) != snapshot["graphHash"]:
                raise ComfyError("The saved execution snapshot is inconsistent.", "invalid_execution_snapshot")
            current = await self._runtime_identity(snapshot)
            if digest_json(current) != snapshot.get("dependencyFingerprint"):
                raise ComfyError("The queued task's model or runtime changed. Restore its pinned dependencies before creating new work.", "dependency_changed")
        status = await self.preflight(preset_id, snapshot)
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

    async def queue_idle(self) -> bool:
        """Fail closed on partial/malformed queue replies; a timeout is never release evidence."""
        queue = await self._json("GET", "/queue")
        if not all(isinstance(queue.get(key), list) for key in ("queue_running", "queue_pending")):
            raise ComfyError("ComfyUI returned an incomplete queue state.", "comfy_invalid_response", True)
        return not self._queue_items(queue)

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
            diagnostic = " ".join(str(m[1].get("exception_type", "")) + " " + str(m[1].get("exception_message", "")) for m in errors if len(m) > 1 and isinstance(m[1], dict)).lower()
            code = "out_of_memory" if any(word in diagnostic for word in ("outofmemory", "out of memory", "cuda error: memory allocation")) else "generation_failed"
            return {"state": "failed", "outputs": [], "error": "The GPU ran out of memory. No lower-quality fallback was used." if code == "out_of_memory" else reason, "code": code}
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

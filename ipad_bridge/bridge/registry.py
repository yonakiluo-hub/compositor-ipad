"""Server-owned, versioned workflow catalogue and immutable enqueue snapshots.

The catalogue is configuration, never client input. Runtime installation,
preflight, GPU smoke and artistic acceptance are independent evidence; loading a
JSON graph proves none of them. All returned values are detached copies.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
import re
from pathlib import Path


class RegistryError(ValueError):
    def __init__(self, message: str, code: str = "invalid_preset"):
        super().__init__(message)
        self.code = code


def graph_hash(graph: dict) -> str:
    return hashlib.sha256(json.dumps(
        graph, sort_keys=True, ensure_ascii=False, separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")).hexdigest()


class PresetRegistry:
    """Read the manifest once; verify each graph against its pinned content hash.

    Broken individual entries stay visible as unavailable and never prevent a
    healthy preset from being used. Changes to a manifest require a new registry
    (normally a service restart); queued snapshots never consult it again.
    """

    def __init__(self, preset_dir: Path, enabled_experimental: bool = False):
        self.preset_dir = Path(preset_dir).resolve()
        self.enabled_experimental = enabled_experimental
        try:
            manifest = json.loads((self.preset_dir / "manifest.json").read_text("utf-8"))
            if not isinstance(manifest, dict) or manifest.get("formatVersion") != 1:
                raise ValueError()
            entries = manifest["presets"]
            if not isinstance(entries, list) or not entries:
                raise ValueError()
            self._entries = {}
            for entry in entries:
                if not isinstance(entry, dict):
                    raise ValueError()
                preset_id = entry.get("id")
                if not isinstance(preset_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,79}", preset_id):
                    raise ValueError()
                if preset_id in self._entries:
                    raise ValueError()
                self._entries[preset_id] = copy.deepcopy(entry)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise RegistryError("The server preset catalogue is invalid.") from exc
        # V1 clients select presets[0]. Retain that behavior across additions.
        self._order = sorted(self._entries, key=lambda item: item != "paint-edit-v1")

    def _entry(self, preset_id: str) -> dict:
        if not isinstance(preset_id, str) or preset_id not in self._entries:
            raise RegistryError("Unknown workflow preset.", "unknown_preset")
        return copy.deepcopy(self._entries[preset_id])

    @staticmethod
    def _enabled(entry: dict, enabled_experimental: bool) -> bool:
        return entry.get("enabled", True) is True and (
            entry.get("experimental", False) is not True or enabled_experimental
        )

    def load(self, preset_id: str, *, allow_disabled: bool = False) -> tuple[dict, dict]:
        entry = self._entry(preset_id)
        if not allow_disabled and not self._enabled(entry, self.enabled_experimental):
            raise RegistryError("This experimental preset is not enabled on the server.", "preset_disabled")
        try:
            for flag in ("enabled", "experimental"):
                if flag in entry and type(entry[flag]) is not bool:
                    raise ValueError()
            version = entry["presetVersion"]
            if not isinstance(version, str) or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
                raise ValueError()
            relative = entry["graph"]
            if not isinstance(relative, str) or "\\" in relative or ":" in relative:
                raise ValueError()
            path = (self.preset_dir / relative).resolve()
            if not path.is_relative_to(self.preset_dir) or path.suffix != ".json":
                raise ValueError()
            graph = json.loads(path.read_text("utf-8"))
            if not isinstance(graph, dict) or not graph:
                raise ValueError()
            expected = entry["graphHash"]
            if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
                raise ValueError()
            if graph_hash(graph) != expected:
                raise RegistryError("The workflow content differs from its registered version.", "preset_changed")
            for node_id, node in graph.items():
                if not isinstance(node_id, str) or not isinstance(node, dict):
                    raise ValueError()
                if not isinstance(node.get("class_type"), str) or not isinstance(node.get("inputs"), dict):
                    raise ValueError()
            bindings = entry["bindings"]
            if not isinstance(bindings, dict) or set(bindings) != {"image", "prompt", "seed", "outputPrefix"}:
                raise ValueError()
            for binding in bindings.values():
                if not isinstance(binding, dict) or set(binding) != {"node", "input"}:
                    raise ValueError()
                if binding["input"] not in graph[binding["node"]]["inputs"]:
                    raise ValueError()
            dependencies = entry["dependencies"]
            if not isinstance(dependencies, list) or not dependencies:
                raise ValueError()
            seen = set()
            model_fields = {
                "unet_name": "diffusion_models", "clip_name": "text_encoders",
                "vae_name": "vae", "lora_name": "loras", "ckpt_name": "checkpoints",
                "control_net_name": "controlnet",
            }
            for dependency in dependencies:
                node_id, input_name = dependency["node"], dependency["input"]
                key = (node_id, input_name)
                if key in seen:
                    raise ValueError()
                seen.add(key)
                node = graph[node_id]
                if node["class_type"] != dependency["loader"] or node["inputs"][input_name] != dependency["filename"]:
                    raise ValueError()
                filename = dependency["filename"]
                if not isinstance(filename, str) or not filename or any(char in filename for char in ("/", "\\", ":")):
                    raise ValueError()
                if dependency["category"] not in {"diffusion_models", "text_encoders", "vae", "loras", "checkpoints", "controlnet"}:
                    raise ValueError()
                if input_name in model_fields and dependency["category"] != model_fields[input_name]:
                    raise ValueError()
                digest = dependency.get("sha256")
                if digest is not None and (not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
                    raise ValueError()
                if dependency.get("revision") is not None and not isinstance(dependency["revision"], str):
                    raise ValueError()
            # A forgotten LoRA or encoder must not bypass artifact fingerprinting.
            required_dependencies = {
                (node_id, name) for node_id, node in graph.items()
                for name in node["inputs"] if name in model_fields
            }
            if not required_dependencies <= seen:
                raise ValueError()
            for field in ("license", "precision", "controls", "limits"):
                if not isinstance(entry[field], dict):
                    raise ValueError()
            limits = entry["limits"]
            if (type(limits.get("maxInputPixels")) is not int or not 1 <= limits["maxInputPixels"] <= 4_194_304
                    or type(limits.get("minimumInputSide")) is not int or limits["minimumInputSide"] < 1
                    or limits["minimumInputSide"] ** 2 > limits["maxInputPixels"]
                    or type(limits.get("maximumAspectRatio")) not in (int, float)
                    or not math.isfinite(limits["maximumAspectRatio"]) or not 1 <= limits["maximumAspectRatio"] <= 16
                    or type(limits.get("maxImages")) is not int or limits["maxImages"] != 1
                    or type(limits.get("maxResults")) is not int or limits["maxResults"] != 1):
                raise ValueError()
            for field in ("inputRoles", "scenarios"):
                if not isinstance(entry[field], list):
                    raise ValueError()
        except RegistryError:
            raise
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise RegistryError("The server configuration for this preset is invalid.") from exc
        return entry, graph

    def descriptor(self, preset_id: str) -> dict:
        entry = self._entry(preset_id)
        enabled = self._enabled(entry, self.enabled_experimental)
        error = None
        try:
            self.load(preset_id, allow_disabled=True)
        except RegistryError as exc:
            error = {"code": exc.code, "message": str(exc)}
        result = {key: copy.deepcopy(entry[key]) for key in (
            "id", "name", "description", "presetVersion", "graphHash", "technique",
            "experimental", "license", "precision", "scenarios", "inputRoles", "controls",
            "limits", "dependencies", "modelMegapixels", "minimumInputSide",
            "maximumAspectRatio", "steps", "customNodesRequired",
        ) if key in entry}
        result.update({
            # These fields are non-optional in the shipped Swift V1 decoder.
            "technique": "reference_edit_with_output_mask",
            "nativeInpainting": False,
            "maskAppliedToOutput": True,
            "default": preset_id == "paint-edit-v1",
            "enabled": enabled,
            "configured": error is None,
            "error": error,
            # A catalogue entry is not evidence about the machine currently running it.
            "qualification": {
                "installed": "not_checked", "structuralPreflight": "not_checked",
                "gpuSmoke": "not_checked", "qualityAdmission": "pending",
            },
        })
        return result

    def descriptors(self) -> list[dict]:
        return [self.descriptor(preset_id) for preset_id in self._order]

    def ids(self) -> tuple[str, ...]:
        return tuple(item["id"] for item in self.descriptors() if item["enabled"] and item["configured"])

    def freeze(self, preset_id: str, metadata: dict) -> dict:
        entry, graph = self.load(preset_id)
        prompt, seed = metadata.get("prompt"), metadata.get("seed")
        if not isinstance(prompt, str) or not prompt.strip() or not 1 <= len(prompt) <= 4000:
            raise RegistryError("A prompt between 1 and 4000 characters is required.", "invalid_prompt")
        if type(seed) is not int or not 0 <= seed <= 2**63 - 1:
            raise RegistryError("The seed must be an integer from 0 to 9223372036854775807.", "invalid_seed")
        snapshot = {
            "schemaVersion": 1, "presetId": preset_id,
            "presetVersion": entry["presetVersion"], "graphHash": entry["graphHash"],
            "graph": graph, "bindings": entry["bindings"],
            "dependencies": entry["dependencies"], "parameters": {"prompt": prompt, "seed": seed},
            "inputMapping": {
                "image": {"role": "sourceImage", "file": "input.png"},
                "mask": {"role": "compositeMask", "file": "mask.png", "sentToModel": False},
            },
            "geometry": {key: copy.deepcopy(metadata[key]) for key in (
                "canvasSize", "cropRect", "inputSize", "colorSpace", "maskConvention",
            ) if key in metadata},
        }
        for key in ("technique", "license", "precision", "controls", "limits", "inputRoles", "scenarios", "experimental"):
            if key in entry:
                snapshot[key] = copy.deepcopy(entry[key])
        snapshot["qualification"] = self.descriptor(preset_id)["qualification"]
        return copy.deepcopy(snapshot)

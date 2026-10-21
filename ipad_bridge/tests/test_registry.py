"""Configuration isolation and enqueue immutability, without a GPU dependency."""
import copy
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from bridge.registry import PresetRegistry, RegistryError, graph_hash


PRESETS = Path(__file__).resolve().parents[1] / "bridge" / "presets"
META = {"workflowPreset": "paint-edit-v1", "prompt": "Keep the lines; add warm colors.", "seed": 42,
        "inputSize": {"width": 768, "height": 768},
        "cropRect": {"x": 20, "y": 30, "width": 768, "height": 768}}


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "presets"
        shutil.copytree(PRESETS, self.root)
        self.manifest = json.loads((self.root / "manifest.json").read_text("utf-8"))
        # Keep fixtures independent of how many experimental graphs ship later.
        self.manifest["presets"] = [self.manifest["presets"][0]]
        self.save()

    def save(self):
        (self.root / "manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")

    def add_experiment(self, **changes):
        entry = copy.deepcopy(self.manifest["presets"][0])
        entry.update(id="new-edit-v1", experimental=True, presetVersion="0.1.0", **changes)
        self.manifest["presets"].insert(0, entry)
        self.save()
        return entry

    def test_legacy_default_stays_first_with_experimental_selection(self):
        self.add_experiment()
        registry = PresetRegistry(self.root, enabled_experimental=True)
        self.assertEqual(registry.ids(), ("paint-edit-v1", "new-edit-v1"))
        self.assertEqual(registry.descriptors()[0]["id"], "paint-edit-v1")

    def test_experimental_is_visible_but_cannot_be_selected_by_default(self):
        self.add_experiment()
        registry = PresetRegistry(self.root)
        self.assertEqual(registry.ids(), ("paint-edit-v1",))
        status = registry.descriptor("new-edit-v1")
        self.assertFalse(status["enabled"])
        self.assertTrue(status["configured"])
        with self.assertRaises(RegistryError) as caught:
            registry.freeze("new-edit-v1", META)
        self.assertEqual(caught.exception.code, "preset_disabled")

    def test_frozen_parameters_graph_and_geometry_are_independent_copies(self):
        registry = PresetRegistry(self.root)
        metadata = copy.deepcopy(META)
        frozen = registry.freeze("paint-edit-v1", metadata)
        self.assertEqual(frozen["parameters"]["seed"], 42)
        self.assertEqual(frozen["geometry"]["cropRect"]["x"], 20)
        metadata["cropRect"]["x"] = 999
        frozen["graph"]["7"]["inputs"]["text"] = "modified"
        frozen["dependencies"][0]["filename"] = "different.safetensors"
        frozen["bindings"]["seed"]["node"] = "999"
        another = registry.freeze("paint-edit-v1", META)
        self.assertNotEqual(another["graph"]["7"]["inputs"]["text"], "modified")
        self.assertEqual(another["dependencies"][0]["filename"], "flux-2-klein-4b-fp8.safetensors")
        self.assertEqual(another["bindings"]["seed"]["node"], "15")
        self.assertEqual(frozen["geometry"]["cropRect"]["x"], 20)

    def test_graph_change_after_enqueue_does_not_change_frozen_job(self):
        registry = PresetRegistry(self.root)
        frozen = registry.freeze("paint-edit-v1", META)
        path = self.root / "paint-edit-v1.json"
        changed = json.loads(path.read_text("utf-8"))
        changed["17"]["inputs"]["steps"] = 8
        path.write_text(json.dumps(changed), encoding="utf-8")
        with self.assertRaises(RegistryError) as caught:
            registry.freeze("paint-edit-v1", META)
        self.assertEqual(caught.exception.code, "preset_changed")
        self.assertEqual(frozen["graph"]["17"]["inputs"]["steps"], 4)
        self.assertEqual(graph_hash(frozen["graph"]), frozen["graphHash"])

    def test_manifest_change_requires_new_registry(self):
        registry = PresetRegistry(self.root)
        self.manifest["presets"][0]["presetVersion"] = "1.1.0"
        self.save()
        self.assertEqual(registry.freeze("paint-edit-v1", META)["presetVersion"], "1.0.0")
        self.assertEqual(PresetRegistry(self.root).freeze("paint-edit-v1", META)["presetVersion"], "1.1.0")

    def test_broken_preset_does_not_block_other_presets(self):
        self.add_experiment(graph="missing.json")
        registry = PresetRegistry(self.root, enabled_experimental=True)
        self.assertEqual(registry.ids(), ("paint-edit-v1",))
        self.assertFalse(registry.descriptor("new-edit-v1")["configured"])
        self.assertEqual(registry.freeze("paint-edit-v1", META)["parameters"]["seed"], 42)

    def test_missing_version_or_invalid_digest_only_disables_its_preset(self):
        for changes in ({"presetVersion": "latest"}, {"presetVersion": "01.0.0"}, {"graphHash": "unknown"}):
            with self.subTest(changes=changes):
                self.manifest["presets"] = self.manifest["presets"][-1:]
                # Avoid duplicate keyword arguments in add_experiment.
                entry = self.add_experiment()
                entry.update(changes)
                self.save()
                registry = PresetRegistry(self.root, enabled_experimental=True)
                self.assertEqual(registry.ids(), ("paint-edit-v1",))

    def test_graph_cannot_escape_server_preset_directory(self):
        for path in ("../paint-edit-v1.json", "C:/private/graph.json", "..\\private\\graph.json"):
            with self.subTest(path=path):
                self.manifest["presets"] = self.manifest["presets"][-1:]
                self.add_experiment(graph=path)
                registry = PresetRegistry(self.root, enabled_experimental=True)
                with self.assertRaises(RegistryError) as caught:
                    registry.load("new-edit-v1")
                self.assertEqual(caught.exception.code, "invalid_preset")
                self.assertNotIn(path, str(caught.exception))

    def test_declared_dependency_must_match_actual_graph(self):
        entry = self.add_experiment()
        entry["dependencies"][0]["filename"] = "wrong.safetensors"
        self.save()
        registry = PresetRegistry(self.root, enabled_experimental=True)
        with self.assertRaises(RegistryError):
            registry.freeze("new-edit-v1", META)
        self.assertEqual(registry.ids(), ("paint-edit-v1",))

    def test_omitted_model_dependency_cannot_bypass_runtime_fingerprint(self):
        entry = self.add_experiment()
        entry["dependencies"].pop()
        self.save()
        registry = PresetRegistry(self.root, enabled_experimental=True)
        with self.assertRaises(RegistryError):
            registry.freeze("new-edit-v1", META)

    def test_all_shipped_presets_have_consistent_pins_and_separate_gates(self):
        registry = PresetRegistry(PRESETS, enabled_experimental=True)
        self.assertEqual(len(registry.ids()), len(registry.descriptors()))
        for preset_id in registry.ids():
            with self.subTest(preset=preset_id):
                entry, graph = registry.load(preset_id)
                self.assertEqual(entry["graphHash"], graph_hash(graph))
        self.assertEqual(PresetRegistry(PRESETS).ids(), ("paint-edit-v1",))

    def test_descriptors_keep_required_v1_swift_decoder_fields(self):
        for descriptor in PresetRegistry(PRESETS).descriptors():
            with self.subTest(preset=descriptor["id"]):
                self.assertEqual(descriptor["technique"], "reference_edit_with_output_mask")
                self.assertIs(descriptor["nativeInpainting"], False)
                self.assertIs(descriptor["maskAppliedToOutput"], True)

    def test_malformed_limits_disable_only_the_affected_preset(self):
        valid = copy.deepcopy(self.manifest["presets"][0]["limits"])
        cases = [{}, {**valid, "maxInputPixels": 0}, {**valid, "maxInputPixels": 4_194_305},
                 {**valid, "maxInputPixels": True}, {**valid, "minimumInputSide": 0},
                 {**valid, "minimumInputSide": 30000}, {**valid, "maximumAspectRatio": "4"},
                 {**valid, "maximumAspectRatio": 17}, {**valid, "maximumAspectRatio": float("nan")},
                 {**valid, "maxImages": 2}, {**valid, "maxResults": 2}, {**valid, "maxImages": True}]
        for limits in cases:
            with self.subTest(limits=limits):
                self.manifest["presets"] = self.manifest["presets"][-1:]
                self.add_experiment(limits=limits)
                registry = PresetRegistry(self.root, enabled_experimental=True)
                self.assertEqual(registry.ids(), ("paint-edit-v1",))
                self.assertFalse(registry.descriptor("new-edit-v1")["configured"])
                with self.assertRaises(RegistryError):
                    registry.freeze("new-edit-v1", META)

    def test_duplicate_ids_reject_ambiguous_catalogue(self):
        self.manifest["presets"].append(copy.deepcopy(self.manifest["presets"][0]))
        self.save()
        with self.assertRaises(RegistryError):
            PresetRegistry(self.root)

    def test_unknown_id_and_invalid_parameters_have_explicit_errors(self):
        registry = PresetRegistry(self.root)
        with self.assertRaises(RegistryError) as caught:
            registry.load("../private")
        self.assertEqual(caught.exception.code, "unknown_preset")
        for seed in (True, -1, "42", 2**63, None):
            with self.subTest(seed=seed), self.assertRaises(RegistryError) as caught:
                registry.freeze("paint-edit-v1", {**META, "seed": seed})
            self.assertEqual(caught.exception.code, "invalid_seed")
        for prompt in ("", "   ", "x" * 4001, None):
            with self.subTest(prompt=prompt), self.assertRaises(RegistryError) as caught:
                registry.freeze("paint-edit-v1", {**META, "prompt": prompt})
            self.assertEqual(caught.exception.code, "invalid_prompt")

    def test_snapshot_does_not_pretend_catalogue_proves_runtime_or_quality(self):
        frozen = PresetRegistry(self.root).freeze("paint-edit-v1", META)
        self.assertEqual(frozen["qualification"], {
            "installed": "not_checked", "structuralPreflight": "not_checked",
            "gpuSmoke": "not_checked", "qualityAdmission": "pending",
        })
        self.assertEqual(frozen["inputMapping"]["mask"]["role"], "compositeMask")
        self.assertFalse(frozen["inputMapping"]["mask"]["sentToModel"])
        self.assertIsNone(frozen["dependencies"][0]["sha256"])
        self.assertNotIn(str(self.root), json.dumps(frozen))

    def test_formatting_change_does_not_change_semantic_graph_hash(self):
        registry = PresetRegistry(self.root)
        entry, graph = registry.load("paint-edit-v1")
        (self.root / "paint-edit-v1.json").write_text(json.dumps(graph, indent=7), encoding="utf-8")
        self.assertEqual(registry.load("paint-edit-v1")[0]["graphHash"], entry["graphHash"])


if __name__ == "__main__":
    unittest.main()

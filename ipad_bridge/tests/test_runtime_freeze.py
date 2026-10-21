"""Runtime attestation and provenance use mock HTTP/OS evidence, never a GPU."""
import copy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

from bridge.comfy import ComfyBackend, ComfyError
from bridge.identity import digest_json
from bridge.local_runtime import LocalRuntimeError


PRESETS = Path(__file__).resolve().parents[1] / "bridge" / "presets"
PACKAGES = [
    {"name": "comfy-kitchen", "installed": "0.2.7", "required": "0.2.7", "extra": "not-part-of-provenance"},
    {"name": "comfy-aimdo", "installed": "0.2.9", "required": "0.2.9"},
]


class RuntimeFreezeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.backend = ComfyBackend("http://127.0.0.1:8388", PRESETS)
        self.addAsyncCleanup(self.backend.close)
        self.system = {"argv": ["mock-main.py", "--mock"], "comfyui_version": "0.34.0",
                       "pytorch_version": "2.11.0", "python_version": "3.12.12", "comfy_package_versions": copy.deepcopy(PACKAGES)}
        self.backend._json = AsyncMock(return_value={"system": self.system})
        self.backend._verify_local_runtime = Mock()
        self.local = {"weights": [{"filename": "sample.safetensors", "sha256": "a" * 64}],
                      "sourceSha256": "b" * 64, "sourceFileCount": 100}
        self.backend.identity.capture = Mock(return_value=self.local)
        self.instance = {"pid": 123, "startedAt": 1000.0}
        self.attest = self.enterContext(patch("bridge.comfy.attest_local_runtime", return_value=self.instance))
        self.snapshot = {"dependencies": [{"category": "diffusion_models", "filename": "sample.safetensors"}]}

    async def test_capture_is_bound_to_same_process_before_and_after_hashing(self):
        evidence = await self.backend._runtime_identity(self.snapshot)
        self.assertEqual(self.attest.call_count, 2)
        self.attest.assert_called_with("http://127.0.0.1:8388", self.system["argv"])
        self.backend.identity.capture.assert_called_once_with(self.snapshot["dependencies"], 1000.0)
        self.backend._verify_local_runtime.assert_called_once_with(self.system)
        self.assertEqual(evidence["weights"], self.local["weights"])
        self.assertEqual(evidence["versions"]["packages"], [
            {"name": "comfy-aimdo", "installed": "0.2.9", "required": "0.2.9"},
            {"name": "comfy-kitchen", "installed": "0.2.7", "required": "0.2.7"},
        ])
        self.assertNotIn("argv", str(evidence))

    async def test_restart_or_pid_reuse_during_hashing_rejects_snapshot(self):
        for changed in ({"pid": 456, "startedAt": 1000.0}, {"pid": 123, "startedAt": 1100.0}):
            with self.subTest(instance=changed):
                self.attest.side_effect = [self.instance, changed]
                with self.assertRaises(ComfyError) as caught:
                    await self.backend._runtime_identity(self.snapshot)
                self.assertEqual(caught.exception.code, "dependency_identity_unavailable")

    async def test_unverifiable_process_does_not_hash_or_accept_weights(self):
        self.attest.side_effect = LocalRuntimeError("The listener could not be verified.")
        with self.assertRaises(ComfyError) as caught:
            await self.backend._runtime_identity(self.snapshot)
        self.assertEqual(caught.exception.code, "dependency_identity_unavailable")
        self.backend.identity.capture.assert_not_called()

    async def test_exact_package_version_changes_dependency_fingerprint(self):
        first = await self.backend._runtime_identity(self.snapshot)
        self.system["comfy_package_versions"].reverse()
        self.assertEqual(first, await self.backend._runtime_identity(self.snapshot))
        self.system["comfy_package_versions"][0]["installed"] = "0.2.10"
        changed = await self.backend._runtime_identity(self.snapshot)
        self.assertNotEqual(digest_json(first), digest_json(changed))

    async def test_incomplete_or_ambiguous_package_versions_fail_closed(self):
        cases = (None, [], {}, [None], ["package"], [{"name": "x", "installed": None}],
                 [{"name": "", "installed": "1"}], [{"name": 42, "installed": "1"}],
                 [{"name": "x", "installed": "1"}, {"name": "x", "installed": "2"}])
        for packages in cases:
            with self.subTest(packages=packages):
                self.system["comfy_package_versions"] = packages
                with self.assertRaises(ComfyError) as caught:
                    await self.backend._runtime_identity(self.snapshot)
                self.assertEqual(caught.exception.code, "runtime_identity_unavailable")

    async def test_runtime_configuration_rejects_custom_node_and_model_root_overrides(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install, models = root / "comfy", root / "models"
            install.mkdir()
            models.mkdir()
            (install / "main.py").write_text("# mock entry point", encoding="utf-8")
            self.backend.identity.install_dir = install
            self.backend.identity.models_dir = models
            argv = [str(install / "main.py"), "--models-directory", str(models),
                    "--disable-all-custom-nodes", "--disable-api-nodes"]
            ComfyBackend._verify_local_runtime(self.backend, {"argv": argv})
            for additions in (["--whitelist-custom-nodes", "untracked-node"],
                              ["--whitelist-custom-nodes=untracked-node"],
                              ["--whitelist-custom-nod", "untracked-node"],
                              ["--models-dir", str(root / "other-models")],
                              ["--models-directory=" + str(root / "other-models")]):
                with self.subTest(additions=additions):
                    with self.assertRaises(ComfyError) as caught:
                        ComfyBackend._verify_local_runtime(self.backend, {"argv": argv + additions})
                    self.assertEqual(caught.exception.code, "runtime_configuration_mismatch")


if __name__ == "__main__":
    unittest.main()

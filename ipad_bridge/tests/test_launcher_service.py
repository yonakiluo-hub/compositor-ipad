import json
import subprocess
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from launcher.config import LauncherConfig, load_config, save_config
from launcher.service import LauncherError, ServiceManager, startup_lock


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.lock_directory = patch("launcher.service.tempfile.gettempdir", return_value=str(self.root))
        self.lock_directory.start()
        self.python = self.root / "python.exe"
        self.python.touch()
        self.config = LauncherConfig(bridge_python=str(self.python), data_dir=str(self.root / "data"),
            comfy_install=str(self.root / "comfy"), models_dir=str(self.root / "models"),
            runtime_dir=str(self.root / "runtime"), lan_address="192.168.30.7")
        self.manager = ServiceManager(self.config, startup_timeout=0.01)
        self.token = "test-launcher-token-" + "x" * 32
        self.capabilities = {"protocolVersion": 1, "backend": "comfyui", "isSimulation": False,
                             "jobDeletionSupported": True}
        self.backend = {"ok": True, "backend": "comfyui", "isSimulation": False}
        self.health = {"service": "compositor-local-bridge", "protocolVersion": 1, "status": "ok"}

    def tearDown(self):
        self.lock_directory.stop()
        self.temp.cleanup()

    def pair(self, address=None):
        root = Path(self.config.data_dir)
        root.mkdir(exist_ok=True)
        (root / "access-token.txt").write_text(self.token)
        pairing = {"protocolVersion": 1, "baseUrl": address or self.config.base_url,
                   "accessToken": self.token, "backend": "comfyui"}
        self.config.pairing_path.write_text(json.dumps(pairing))

    def response(self, origin, path, token=None, timeout=4):
        if path == "/system_stats":
            return 200, {"system": {"comfyui_version": "test"}, "devices": []}
        if path == "/health":
            return 200, self.health
        if token != self.token:
            return 401, {}
        if path == "/v1/capabilities":
            return 200, self.capabilities
        if path == "/v1/backend/status":
            return 200, self.backend
        raise AssertionError(path)

    def healthy(self):
        return patch.multiple(self.manager, _json=self.response, _network_check=lambda: (True, "test LAN"),
                              _port_open=lambda _: True, _bridge_parameters_match=lambda: True)

    def files(self):
        return {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*")
                if p.is_file() and p.name != "compositor-windows-launcher.lock"}

    def test_status_is_read_only_even_when_no_credentials_exist(self):
        before = self.files()
        with patch.multiple(self.manager, _json=lambda *a, **kw: (None, None),
                            _network_check=lambda: (True, "LAN"), _port_open=lambda _: False):
            result = self.manager.status()
        self.assertFalse(result["ready"])
        self.assertEqual(before, self.files())
        self.assertFalse(Path(self.config.data_dir).exists())

    def test_healthy_start_reuses_processes_and_pairing_exact_bytes(self):
        self.pair()
        before = self.files()
        with self.healthy(), patch.object(self.manager, "_launch_comfy") as comfy, patch.object(self.manager, "_launch_bridge") as bridge:
            result = self.manager.start()
        self.assertTrue(result["ready"])
        comfy.assert_not_called()
        bridge.assert_not_called()
        self.assertEqual(before, self.files())
        self.assertNotIn(self.token, json.dumps(result))

    def test_http_200_not_ready_does_not_report_success(self):
        self.pair()
        self.backend.update(ok=False, missingModels=["missing-test-model.safetensors"])
        with self.healthy():
            result = self.manager.status()
        self.assertFalse(result["ready"])
        self.assertTrue(any("missing-test-model" in check["message"] for check in result["checks"]))

    def test_existing_wrong_bridge_never_changes_pairing_or_starts_gpu(self):
        for failure in ("wrong_service", "wrong_token", "mock", "wrong_process"):
            with self.subTest(failure=failure):
                self.pair()
                before = self.files()
                self.health["service"] = "other" if failure == "wrong_service" else "compositor-local-bridge"
                self.capabilities["backend"] = "mock" if failure == "mock" else "comfyui"
                response = self.response
                if failure == "wrong_token":
                    response = lambda origin, path, token=None, timeout=4: (401, {}) if path.startswith("/v1/") else self.response(origin, path)
                with patch.multiple(self.manager, _json=response, _network_check=lambda: (True, "LAN"),
                                    _port_open=lambda _: True, _bridge_parameters_match=lambda: failure != "wrong_process"), \
                        patch.object(self.manager, "_launch_comfy") as launch:
                    with self.assertRaises(LauncherError):
                        self.manager.start()
                    launch.assert_not_called()
                self.assertEqual(before, self.files())

    def test_new_address_updates_pairing_without_replacing_token_or_data(self):
        self.pair("http://192.168.30.6:8190")
        data = Path(self.config.data_dir) / "artwork.comp.zip"
        data.write_bytes(b"existing artwork")
        with self.healthy():
            before = self.manager.status()
            self.assertFalse(before["ready"])
            result = self.manager.start()
        self.assertTrue(result["ready"])
        pairing = json.loads(self.config.pairing_path.read_text())
        self.assertEqual(pairing["accessToken"], self.token)
        self.assertEqual(pairing["baseUrl"], self.config.base_url)
        self.assertEqual(data.read_bytes(), b"existing artwork")
        self.assertTrue(any(check["name"] == "配对更新" for check in result["checks"]))

    def test_wrong_pairing_and_missing_credential_with_existing_database_are_not_replaced(self):
        self.pair()
        pairing = json.loads(self.config.pairing_path.read_text())
        pairing["accessToken"] = "different" * 8
        self.config.pairing_path.write_text(json.dumps(pairing))
        before = self.files()
        with self.healthy(), self.assertRaises(LauncherError):
            self.manager.start()
        self.assertEqual(before, self.files())
        self.config.pairing_path.unlink()
        (Path(self.config.data_dir) / "access-token.txt").unlink()
        (Path(self.config.data_dir) / "jobs.sqlite3").write_bytes(b"existing")
        with self.healthy(), self.assertRaises(LauncherError):
            self.manager.start()
        self.assertFalse((Path(self.config.data_dir) / "access-token.txt").exists())

    def test_inactive_lan_address_never_starts_processes(self):
        self.pair()
        with patch.object(self.manager, "_network_check", return_value=(False, "address changed")), \
                patch.object(self.manager, "_launch_comfy") as launch:
            with self.assertRaisesRegex(LauncherError, "address changed"):
                self.manager.start()
            launch.assert_not_called()

    def test_unrelated_comfy_listener_is_not_replaced(self):
        self.pair()
        with self.healthy(), patch.object(self.manager, "_comfy_ready", return_value=False), \
                patch.object(self.manager, "_launch_comfy") as launch:
            with self.assertRaisesRegex(LauncherError, "端口"):
                self.manager.start()
            launch.assert_not_called()

    def test_startup_lock_rejects_second_launcher(self):
        with startup_lock():
            with self.assertRaises(LauncherError):
                with startup_lock():
                    self.fail("Must not acquire the same lock twice")

    def test_timed_out_process_is_not_spawned_again(self):
        self.pair()
        identity = {"created": "test-start", "commandHash": "test-command"}
        with patch("launcher.service._process_stamp", return_value=identity):
            self.manager._record("ComfyUI", 12345)
        with patch.multiple(self.manager, _network_check=lambda: (True, "LAN"),
                            _port_open=lambda _: False, _comfy_ready=lambda: False), \
                patch("launcher.service._alive", return_value=True), patch("launcher.service._process_stamp", return_value=identity), \
                patch.object(self.manager, "_launch_comfy") as launch:
            with self.assertRaisesRegex(LauncherError, "重复启动"):
                self.manager.start()
            launch.assert_not_called()

    def test_reused_pid_is_not_mistaken_for_pending_service(self):
        self.pair()
        identity = {"created": "old-start", "commandHash": "test-command"}
        with patch("launcher.service._process_stamp", return_value=identity):
            self.manager._record("ComfyUI", 12345)
        for current in ({"created": "new-start", "commandHash": "test-command"},
                        {"created": "old-start", "commandHash": "different-command"}):
            with patch("launcher.service._alive", return_value=True), patch("launcher.service._process_stamp", return_value=current):
                self.assertFalse(self.manager._pending_process("ComfyUI"))

    def test_changed_settings_diagnose_existing_process_instead_of_waiting_forever(self):
        self.pair()
        identity = {"created": "same-start", "commandHash": "test-command"}
        with patch("launcher.service._process_stamp", return_value=identity):
            self.manager._record("ComfyUI", 12345)
            changed = ServiceManager(replace(self.config, comfy_port=8389))
            with patch("launcher.service._alive", return_value=True), self.assertRaisesRegex(LauncherError, "旧设置"):
                changed._pending_process("ComfyUI")

    def test_identity_read_failure_keeps_pending_process_and_prevents_duplicate(self):
        self.pair()
        with patch("launcher.service._process_stamp", return_value=None):
            with self.assertRaises(LauncherError):
                self.manager._record("ComfyUI", 12345)
        with patch.multiple(self.manager, _network_check=lambda: (True, "LAN"),
                            _port_open=lambda _: False, _comfy_ready=lambda: False), \
                patch("launcher.service._alive", return_value=True), patch.object(self.manager, "_launch_comfy") as launch:
            with self.assertRaisesRegex(LauncherError, "尚未确认"):
                self.manager.start()
            launch.assert_not_called()

    def test_unknown_helper_result_keeps_intent_and_prevents_duplicate(self):
        self.pair()
        self.manager._intent("ComfyUI")
        with patch.multiple(self.manager, _network_check=lambda: (True, "LAN"),
                            _port_open=lambda _: False, _comfy_ready=lambda: False), patch.object(self.manager, "_launch_comfy") as launch:
            with self.assertRaisesRegex(LauncherError, "尚未确认"):
                self.manager.start()
            launch.assert_not_called()

    def test_record_write_failure_preserves_prelaunch_intent(self):
        self.pair()
        self.manager._intent("ComfyUI")
        with patch.object(Path, "write_text", side_effect=PermissionError()):
            with self.assertRaises(LauncherError):
                self.manager._record("ComfyUI", 12345)
        with self.assertRaisesRegex(LauncherError, "尚未确认"):
            self.manager._pending_process("ComfyUI")

    def test_failed_bridge_spawn_can_retry_after_python_is_fixed(self):
        self.pair()
        with patch("launcher.service.subprocess.Popen", side_effect=OSError()):
            with self.assertRaisesRegex(LauncherError, "桥接启动失败"):
                self.manager._launch_bridge()
        self.assertFalse(self.manager._pending_process("桥接"))
        with patch("launcher.service.subprocess.Popen") as spawn, \
                patch("launcher.service._process_stamp", return_value={"created": "now", "commandHash": "bridge"}):
            spawn.return_value.pid = 12345
            self.manager._launch_bridge()
        self.assertEqual(self.manager._state()["桥接"]["phase"], "verified")

    def test_bridge_log_failure_does_not_leave_launch_intent(self):
        self.pair()
        with patch.object(Path, "open", side_effect=PermissionError()), \
                patch("launcher.service.subprocess.Popen") as spawn:
            with self.assertRaises(PermissionError):
                self.manager._launch_bridge()
            spawn.assert_not_called()
        self.assertNotIn("桥接", self.manager._state())

    def test_comfy_helper_timeout_preserves_intent_without_retry(self):
        self.pair()
        install = Path(self.config.comfy_install)
        (install / ".venv" / "Scripts").mkdir(parents=True)
        (install / ".venv" / "Scripts" / "python.exe").touch()
        (install / "main.py").touch()
        Path(self.config.models_dir).mkdir()
        with patch("launcher.service.subprocess.run", side_effect=subprocess.TimeoutExpired("helper", 20)):
            with self.assertRaises(LauncherError):
                self.manager._launch_comfy()
        with patch.multiple(self.manager, _network_check=lambda: (True, "LAN"),
                            _port_open=lambda _: False, _comfy_ready=lambda: False), \
                patch("launcher.service.subprocess.run") as helper:
            with self.assertRaisesRegex(LauncherError, "尚未确认"):
                self.manager.start()
            helper.assert_not_called()

    def test_configuration_is_local_atomic_and_rejects_invalid_ports_and_address(self):
        target = self.root / "launcher-private.json"
        save_config(self.config, target)
        self.assertEqual(load_config(target), self.config)
        original = target.read_bytes()
        for invalid in (replace(self.config, bridge_port=0), replace(self.config, bridge_port=8388),
                        replace(self.config, comfy_port=True), replace(self.config, lan_address="198.18.0.1"),
                        replace(self.config, lan_address="127.0.0.1"), replace(self.config, runtime_dir=self.config.data_dir)):
            with self.assertRaises(ValueError):
                save_config(invalid, target)
            self.assertEqual(target.read_bytes(), original)
        target.write_text('{"accessToken":"should-not-be-a-config-field"}')
        with self.assertRaises(ValueError):
            load_config(target)


if __name__ == "__main__":
    unittest.main()

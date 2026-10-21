"""Local process attestation without reading any real process or network table."""
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import psutil

from bridge.local_runtime import LocalRuntimeError, attest_local_runtime


def listener(pid=123, ip="127.0.0.1", port=8388, status=psutil.CONN_LISTEN):
    return SimpleNamespace(pid=pid, laddr=(ip, port), status=status)


class LocalRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.main = Path(self.temp.name) / "main.py"
        self.main.write_text("# test entry point", encoding="utf-8")
        self.argv = [str(self.main), "--listen", "127.0.0.1", "--port", "8388", "--disable-all-custom-nodes"]
        self.started = time.time() - 60
        self.process = Mock()
        self.process.cmdline.return_value = ["python", "-B", "-s", *self.argv]
        self.process.create_time.return_value = self.started
        self.connections = self.enterContext(patch("bridge.local_runtime.psutil.net_connections", return_value=[listener()]))
        self.process_factory = self.enterContext(patch("bridge.local_runtime.psutil.Process", return_value=self.process))

    def test_valid_listener_returns_only_pid_and_start_time(self):
        self.assertEqual(attest_local_runtime("http://127.0.0.1:8388", self.argv), {"pid": 123, "startedAt": self.started})
        self.assertEqual(self.connections.call_count, 2)
        self.connections.assert_called_with(kind="tcp")
        self.assertNotIn(str(self.main), str(attest_local_runtime("http://localhost:8388/", self.argv)))

    def test_non_loopback_or_non_origin_urls_fail_before_process_inspection(self):
        for url in ("http://192.168.1.4:8388", "http://example.com:8388", "file:///tmp/file", "http://127.0.0.1:8388/api",
                    "http://user:secret@127.0.0.1:8388", "http://127.0.0.1:8388?q=x", "http://127.0.0.1:8388#x",
                    "http://127.0.0.1:99999", "http://127.0.0.1:0", "http://127.0.0.1:bad"):
            with self.subTest(url=url), self.assertRaises(LocalRuntimeError) as caught:
                attest_local_runtime(url, self.argv)
            self.assertNotIn(url, str(caught.exception))
        self.connections.assert_not_called()

    def test_ipv6_loopback_and_https_origins_are_supported(self):
        self.connections.return_value = [listener(ip="::1", port=443)]
        self.argv[2], self.argv[4] = "::1", "443"
        self.process.cmdline.return_value = ["python", *self.argv]
        self.assertEqual(attest_local_runtime("https://[::1]", self.argv)["pid"], 123)

    def test_wildcard_listener_is_rejected_even_with_loopback_client_url(self):
        for ip in ("0.0.0.0", "::"):
            with self.subTest(ip=ip), self.assertRaises(LocalRuntimeError):
                self.connections.return_value = [listener(ip=ip)]
                attest_local_runtime("http://127.0.0.1:8388", self.argv)

    def test_no_unknown_or_ambiguous_listener_is_accepted(self):
        for connections in ([], [listener(pid=None)], [listener(pid=0)], [listener(pid=123), listener(pid=456)],
                            [listener(status="ESTABLISHED")], [listener(port=8888)]):
            with self.subTest(connections=connections), self.assertRaises(LocalRuntimeError):
                self.connections.return_value = connections
                attest_local_runtime("http://localhost:8388", self.argv)

    def test_two_loopback_addresses_with_same_pid_are_unambiguous(self):
        self.connections.return_value = [listener(), listener(ip="::1")]
        self.assertEqual(attest_local_runtime("http://localhost:8388", self.argv)["pid"], 123)

    def test_different_main_file_is_rejected(self):
        other = self.main.parent / "other" / "main.py"
        other.parent.mkdir()
        other.write_text("# different install", encoding="utf-8")
        self.process.cmdline.return_value = ["python", str(other), *self.argv[1:]]
        with self.assertRaises(LocalRuntimeError) as caught:
            attest_local_runtime("http://127.0.0.1:8388", self.argv)
        self.assertNotIn(str(other), str(caught.exception))

    def test_arguments_must_match_in_full(self):
        for command in (["python", *self.argv, "--extra-model-paths-config", "private.yaml"],
                        ["python", *self.argv[:-1]], ["python", *self.argv[1:]], "invalid"):
            with self.subTest(command=command), self.assertRaises(LocalRuntimeError):
                self.process.cmdline.return_value = command
                attest_local_runtime("http://127.0.0.1:8388", self.argv)

    def test_invalid_reported_arguments_are_rejected(self):
        for argv in (None, [], "not-list", ["main.py"], [str(self.main), None], [str(self.main), "\x00"], [str(self.main.parent)]):
            with self.subTest(argv=argv), self.assertRaises(LocalRuntimeError):
                attest_local_runtime("http://127.0.0.1:8388", argv)
        self.connections.assert_not_called()

    def test_os_permission_and_process_disappearance_errors_are_sanitized(self):
        for error in (psutil.AccessDenied(pid=123, name=str(self.main)), psutil.NoSuchProcess(pid=123, name=str(self.main))):
            with self.subTest(error=type(error)), self.assertRaises(LocalRuntimeError) as caught:
                self.process.cmdline.side_effect = error
                attest_local_runtime("http://127.0.0.1:8388", self.argv)
            self.assertNotIn(str(self.main), str(caught.exception))
        self.process.cmdline.side_effect = None
        self.connections.side_effect = psutil.AccessDenied(pid=123)
        with self.assertRaises(LocalRuntimeError):
            attest_local_runtime("http://127.0.0.1:8388", self.argv)

    def test_invalid_start_time_is_never_accepted(self):
        for started in (None, True, 0, -1, float("nan"), float("inf"), "today", time.time() + 600):
            with self.subTest(started=started), self.assertRaises(LocalRuntimeError):
                self.process.create_time.return_value = started
                attest_local_runtime("http://127.0.0.1:8388", self.argv)

    def test_listener_or_process_restart_during_inspection_is_rejected(self):
        self.connections.side_effect = [[listener()], [listener(pid=456)]]
        with self.assertRaises(LocalRuntimeError):
            attest_local_runtime("http://127.0.0.1:8388", self.argv)
        self.connections.side_effect = None
        self.process.create_time.side_effect = [self.started, self.started + 30]
        with self.assertRaises(LocalRuntimeError):
            attest_local_runtime("http://127.0.0.1:8388", self.argv)


if __name__ == "__main__":
    unittest.main()

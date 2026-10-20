import json
import subprocess
import unittest
from unittest.mock import patch

from launcher.network import NetworkDiscoveryError, discover_ipv4, suggest_address


def interface(address="192.168.8.10", name="Wi-Fi", **changes):
    value = {
        "address": address,
        "name": name,
        "description": "Wireless adapter",
        "hardwareInterface": True,
        "status": "Up",
        "addressState": "Preferred",
    }
    value.update(changes)
    return value


class NetworkDiscoveryTests(unittest.TestCase):
    def discover(self, payload):
        output = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        completed = subprocess.CompletedProcess([], 0, stdout=output, stderr=b"")
        with patch("launcher.network.sys.platform", "win32"), patch("launcher.network.subprocess.run", return_value=completed) as run:
            result = discover_ipv4()
        self.assertEqual(run.call_args.kwargs["timeout"], 10)
        self.assertEqual(run.call_args.kwargs["creationflags"], getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.assertNotIn("shell", run.call_args.kwargs)
        return result

    def test_single_powershell_object_and_unicode_adapter_name(self):
        adapters = self.discover(interface(name="无线网络"))
        self.assertEqual(adapters[0]["name"], "无线网络")
        self.assertEqual(suggest_address(adapters), "192.168.8.10")

    def test_empty_network_is_not_a_discovery_error(self):
        self.assertEqual(self.discover([]), [])
        self.assertIsNone(suggest_address([]))

    def test_filter_unusable_addresses_and_inactive_interfaces(self):
        unusable = ["127.0.0.1", "169.254.3.4", "0.0.0.0", "0.8.1.2", "::1", "224.0.0.1", "255.255.255.255", "not-an-ip"]
        adapters = self.discover(
            [interface(address=ip) for ip in unusable]
            + [interface(status="Disconnected"), interface(addressState="Duplicate"), interface(addressState="Tentative")]
            + [interface(), interface()]
        )
        self.assertEqual(len(adapters), 1)
        self.assertEqual(adapters[0]["address"], "192.168.8.10")

    def test_virtual_and_vpn_addresses_remain_visible_but_are_not_suggested(self):
        for name in ["Mihomo", "Clash", "WireGuard Tunnel", "TUN", "tap-windows", "Tailscale", "ZeroTier One", "vEthernet", "VMware", "虚拟网卡"]:
            with self.subTest(name=name):
                adapters = self.discover(interface(name=name))
                self.assertTrue(adapters[0]["virtual"])
                self.assertIsNone(suggest_address(adapters, "192.168.8.10"))
        for changes in [{"hardwareInterface": False}, {"hardwareInterface": None}, {"address": "198.18.0.7"}]:
            with self.subTest(changes=changes):
                adapters = self.discover(interface(**changes))
                self.assertTrue(adapters[0]["virtual"])
                self.assertIsNone(suggest_address(adapters))

    def test_vpn_default_route_does_not_hide_physical_lan(self):
        adapters = self.discover([interface(address="198.18.0.7", name="Mihomo"), interface()])
        self.assertEqual(suggest_address(adapters, "198.18.0.7"), "192.168.8.10")

    def test_timeout_and_permissions_produce_readable_errors_without_stderr(self):
        failures = [
            (subprocess.TimeoutExpired("powershell", 10), "超时"),
            (OSError("internal details"), "PowerShell"),
        ]
        for failure, message in failures:
            with self.subTest(failure=failure), patch("launcher.network.sys.platform", "win32"), patch("launcher.network.subprocess.run", side_effect=failure):
                with self.assertRaisesRegex(NetworkDiscoveryError, message):
                    discover_ipv4()
        completed = subprocess.CompletedProcess([], 1, stdout=b"", stderr=b"private diagnostic details")
        with patch("launcher.network.sys.platform", "win32"), patch("launcher.network.subprocess.run", return_value=completed):
            with self.assertRaisesRegex(NetworkDiscoveryError, "权限") as caught:
                discover_ipv4()
            self.assertNotIn("private", str(caught.exception))

    def test_bad_json_is_not_misreported_as_no_network(self):
        for output in [b"", b"Warning: failed", b"null", b"[1]", b"\xff"]:
            with self.subTest(output=output):
                completed = subprocess.CompletedProcess([], 0, stdout=output, stderr=b"")
                with patch("launcher.network.sys.platform", "win32"), patch("launcher.network.subprocess.run", return_value=completed):
                    with self.assertRaises(NetworkDiscoveryError):
                        discover_ipv4()

    def test_unsupported_platform_is_explicit(self):
        with patch("launcher.network.sys.platform", "darwin"), patch("launcher.network.subprocess.run") as run:
            with self.assertRaisesRegex(NetworkDiscoveryError, "仅支持 Windows"):
                discover_ipv4()
            run.assert_not_called()


class AddressSuggestionTests(unittest.TestCase):
    def test_multiple_lans_require_a_choice_unless_current_address_is_valid(self):
        adapters = [
            {"address": "10.8.0.4", "name": "Ethernet", "virtual": False},
            {"address": "192.168.8.10", "name": "Wi-Fi", "virtual": False},
        ]
        self.assertIsNone(suggest_address(adapters))
        self.assertIsNone(suggest_address(adapters, "192.168.8.11"))
        self.assertEqual(suggest_address(adapters, "192.168.8.10"), "192.168.8.10")

    def test_stale_ip_can_be_replaced_by_a_unique_lan_suggestion(self):
        adapter = {"address": "172.31.4.7", "name": "Wi-Fi", "virtual": False}
        self.assertEqual(suggest_address([adapter, adapter], "192.168.8.11"), "172.31.4.7")

    def test_only_rfc1918_addresses_are_auto_suggested(self):
        for address in ["198.18.0.7", "192.0.2.7", "100.64.1.2", "8.8.8.8", "172.32.0.4", "10.0.0.999"]:
            with self.subTest(address=address):
                self.assertIsNone(suggest_address([{"address": address, "virtual": False}], address))

    def test_unknown_interface_type_is_not_assumed_physical(self):
        for value in [None, "false", 0, True]:
            with self.subTest(value=value):
                self.assertIsNone(suggest_address([{"address": "10.8.0.4", "virtual": value}]))


if __name__ == "__main__":
    unittest.main()

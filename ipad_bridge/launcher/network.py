"""Read-only Windows LAN address discovery for the desktop launcher.

Discovery deliberately does not probe an Internet endpoint or change adapter,
routing, or firewall settings. A suggested address is only a UI default; callers
must obtain the user's selection before changing a saved pairing address.
"""

from __future__ import annotations

import ipaddress
import json
import re
import subprocess
import sys
from typing import Any


class NetworkDiscoveryError(RuntimeError):
    """An address-discovery failure with a message suitable for the launcher UI."""


_PRIVATE_NETWORKS = tuple(
    ipaddress.IPv4Network(cidr) for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)
_BENCHMARK_NETWORK = ipaddress.IPv4Network("198.18.0.0/15")
_ZERO_NETWORK = ipaddress.IPv4Network("0.0.0.0/8")
_VIRTUAL_NAMES = re.compile(
    r"vpn|mihomo|clash|wireguard|wintun|tailscale|zerotier|openvpn|"
    r"virtual|vethernet|hyper-v|vmware|virtualbox|loopback|docker|"
    r"(?:^|[\s_\-])(?:tun|tap)(?:$|[\s_\-\d])|虚拟",
    re.IGNORECASE,
)

# ConvertTo-Json receives an explicit array so zero/one adapter does not change
# the result shape. The parser also accepts the single-object form emitted by
# older helper scripts. UTF-8 avoids the system code page corrupting Wi-Fi names.
_DISCOVERY_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$adapterByIndex = @{}
Get-NetAdapter -IncludeHidden -ErrorAction Stop | ForEach-Object {
    $adapterByIndex[[int]$_.ifIndex] = $_
}
$entries = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object {
    $adapter = $adapterByIndex[[int]$_.InterfaceIndex]
    if ($null -ne $adapter -and $adapter.Status -eq 'Up' -and
        $_.AddressState -eq 'Preferred' -and -not $_.SkipAsSource) {
        [PSCustomObject]@{
            address = [string]$_.IPAddress
            name = [string]$adapter.Name
            description = [string]$adapter.InterfaceDescription
            interfaceIndex = [int]$_.InterfaceIndex
            hardwareInterface = [bool]$adapter.HardwareInterface
            status = [string]$adapter.Status
            addressState = [string]$_.AddressState
        }
    }
})
ConvertTo-Json -InputObject @($entries) -Compress -Depth 3
"""


def _ipv4(value: Any) -> ipaddress.IPv4Address | None:
    if not isinstance(value, str):
        return None
    try:
        address = ipaddress.ip_address(value.strip())
    except ValueError:
        return None
    if not isinstance(address, ipaddress.IPv4Address):
        return None
    if (
        address in _ZERO_NETWORK
        or address.is_loopback
        or address.is_link_local
        or address.is_multicast
        or address.is_reserved
    ):
        return None
    return address


def _parse_discovery_output(output: str) -> list[dict[str, Any]]:
    try:
        decoded = json.loads(output.lstrip("\ufeff"))
    except (ValueError, TypeError) as exc:
        raise NetworkDiscoveryError("无法读取 Windows 返回的网卡信息，请重新检查连接。") from exc
    if isinstance(decoded, dict):
        decoded = [decoded]
    if not isinstance(decoded, list) or any(not isinstance(row, dict) for row in decoded):
        raise NetworkDiscoveryError("Windows 返回的网卡信息格式不正确，请重新检查连接。")

    adapters: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for row in decoded:
        address = _ipv4(row.get("address"))
        if address is None or row.get("status") != "Up" or row.get("addressState") != "Preferred":
            continue
        name = row.get("name") if isinstance(row.get("name"), str) else "未命名网卡"
        description = row.get("description") if isinstance(row.get("description"), str) else ""
        virtual = (
            row.get("hardwareInterface") is not True
            or bool(_VIRTUAL_NAMES.search(name + " " + description))
            or address in _BENCHMARK_NETWORK
        )
        key = (str(address), name)
        if key in seen:
            continue
        seen.add(key)
        adapters.append({"address": str(address), "name": name, "virtual": virtual, "description": description})
    adapters.sort(key=lambda row: (row["virtual"], row["name"].casefold(), int(ipaddress.IPv4Address(row["address"]))))
    return adapters


def discover_ipv4() -> list[dict[str, Any]]:
    """List active IPv4 interfaces; return [] when none is usable.

    Each result has ``address``, ``name``, ``virtual`` and ``description``. VPN
    and virtual interfaces remain visible for an informed manual choice, but
    ``suggest_address`` never automatically recommends them. Failures raise
    ``NetworkDiscoveryError``; no raw command output is included in its message.
    """
    if sys.platform != "win32":
        raise NetworkDiscoveryError("自动查找局域网地址仅支持 Windows，请手动填写电脑地址。")
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", _DISCOVERY_SCRIPT],
            capture_output=True,
            timeout=10,
            check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired as exc:
        raise NetworkDiscoveryError("查找局域网地址超时，请检查网络连接后重试。") from exc
    except OSError as exc:
        raise NetworkDiscoveryError("无法读取 Windows 网卡信息，请确认 PowerShell 可用后重试。") from exc
    if result.returncode != 0:
        raise NetworkDiscoveryError("Windows 未能读取网卡信息，请检查网络状态或系统权限后重试。")
    try:
        output = result.stdout.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise NetworkDiscoveryError("无法读取 Windows 返回的网卡名称，请重新检查连接。") from exc
    return _parse_discovery_output(output)


def suggest_address(adapters: list[dict[str, Any]], current: str = "") -> str | None:
    """Suggest a physical RFC1918 address without guessing between LANs.

    Keep the current address only when it is still present on a suitable
    physical interface. Otherwise return the sole eligible address, or None
    when the user must choose. ``IPv4Address.is_private`` is intentionally not
    used: it also includes non-LAN ranges such as VPN benchmarking addresses.
    """
    eligible: set[str] = set()
    for adapter in adapters:
        address = _ipv4(adapter.get("address"))
        if adapter.get("virtual") is False and address is not None and any(address in subnet for subnet in _PRIVATE_NETWORKS):
            eligible.add(str(address))
    old_address = _ipv4(current)
    if old_address is not None and str(old_address) in eligible:
        return str(old_address)
    return next(iter(eligible)) if len(eligible) == 1 else None

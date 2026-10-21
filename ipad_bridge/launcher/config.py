from __future__ import annotations

import ipaddress
import json
import os
import tempfile
from dataclasses import asdict, dataclass, fields
from pathlib import Path

BRIDGE_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = BRIDGE_ROOT / "launcher-private.json"
PRIVATE_NETWORKS = tuple(ipaddress.ip_network(value) for value in
                         ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))


@dataclass(frozen=True)
class LauncherConfig:
    bridge_python: str = str(BRIDGE_ROOT / ".venv" / "Scripts" / "python.exe")
    data_dir: str = str(BRIDGE_ROOT / "data-comfyui")
    comfy_install: str = ""
    models_dir: str = ""
    runtime_dir: str = str(BRIDGE_ROOT / "data-comfy-runtime")
    lan_address: str = ""
    bridge_port: int = 8190
    comfy_port: int = 8388

    @property
    def base_url(self):
        return f"http://{self.lan_address}:{self.bridge_port}"

    @property
    def bridge_url(self):
        return f"http://127.0.0.1:{self.bridge_port}"

    @property
    def comfy_url(self):
        return f"http://127.0.0.1:{self.comfy_port}"

    @property
    def pairing_path(self):
        return Path(self.data_dir) / "pairing.json"

    @property
    def logs_dir(self):
        return Path(self.data_dir) / "launcher-logs"

    def validate(self):
        for name in ("bridge_port", "comfy_port"):
            port = getattr(self, name)
            if type(port) is not int or not 1024 <= port <= 65535:
                raise ValueError("服务端口需要是 1024–65535 之间的整数。")
        if self.bridge_port == self.comfy_port:
            raise ValueError("桥接和 ComfyUI 需要使用不同端口。")
        try:
            address = ipaddress.IPv4Address(self.lan_address)
        except (ipaddress.AddressValueError, TypeError):
            raise ValueError("请在设置中选择 Windows 的局域网 IPv4 地址。") from None
        if not any(address in network for network in PRIVATE_NETWORKS):
            raise ValueError("请选择家庭或工作局域网地址（10、172.16–31 或 192.168 开头）。")
        for name in ("bridge_python", "data_dir", "comfy_install", "models_dir", "runtime_dir"):
            value = getattr(self, name)
            if not isinstance(value, str) or not value.strip() or not Path(value).is_absolute():
                raise ValueError("请在设置中完整选择 Python、ComfyUI、模型、数据和缓存路径。")
        data, runtime = Path(self.data_dir).resolve(), Path(self.runtime_dir).resolve()
        if data == runtime or data in runtime.parents or runtime in data.parents:
            raise ValueError("桥接数据与 ComfyUI 缓存需要使用各自独立的文件夹。")


def load_config(path: Path = DEFAULT_CONFIG) -> LauncherConfig:
    path = Path(path)
    if not path.exists():
        return LauncherConfig()
    try:
        raw = json.loads(path.read_text("utf-8-sig"))
        if not isinstance(raw, dict) or set(raw) - {f.name for f in fields(LauncherConfig)}:
            raise ValueError()
        config = LauncherConfig(**raw)
        config.validate()
        return config
    except (OSError, ValueError, TypeError):
        raise ValueError("本机启动配置无法读取，请打开设置重新选择路径和局域网地址。") from None


def save_config(config: LauncherConfig, path: Path = DEFAULT_CONFIG) -> None:
    config.validate()
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".launcher-", suffix=".tmp", delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(asdict(config), handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import socket
import subprocess
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

import httpx

from .config import BRIDGE_ROOT, LauncherConfig
from .network import NetworkDiscoveryError, discover_ipv4


class LauncherError(RuntimeError):
    pass


def _hidden():
    return subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def _alive(pid):
    if type(pid) is not int or pid <= 0:
        return False
    if os.name == "nt":
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        handle = kernel.OpenProcess(0x00100000, False, pid)
        if not handle:
            return False
        try:
            return kernel.WaitForSingleObject(handle, 0) == 258
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _process_stamp(pid):
    """PID alone is not identity: Windows can reuse it after exit or reboot."""
    if os.name != "nt" or type(pid) is not int or pid <= 0:
        return None
    script = ("[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $OutputEncoding=[Console]::OutputEncoding; "
              f"$p=Get-CimInstance Win32_Process -Filter 'ProcessId={pid}' -ErrorAction Stop; "
              "if($p -and $p.CommandLine) { [pscustomobject]@{created=$p.CreationDate.ToUniversalTime().ToString('o'); command=$p.CommandLine} | ConvertTo-Json -Compress }")
    try:
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                                capture_output=True, timeout=10, creationflags=_hidden())
        value = json.loads(result.stdout.decode("utf-8-sig")) if result.returncode == 0 else None
        if not isinstance(value, dict) or not isinstance(value.get("created"), str) or not isinstance(value.get("command"), str):
            return None
        return {"created": value["created"], "commandHash": hashlib.sha256(value["command"].encode("utf-8")).hexdigest()}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


@contextmanager
def startup_lock():
    """Serialize launchers for this Windows user, including different data directories."""
    path = Path(tempfile.gettempdir()) / "compositor-windows-launcher.lock"
    with path.open("a+b") as handle:
        try:
            handle.seek(0)
            if not handle.read(1):
                handle.write(b"0")
                handle.flush()
            handle.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise LauncherError("另一个启动窗口正在准备服务，请稍后检查连接。") from None
        yield


class ServiceManager:
    def __init__(self, config: LauncherConfig, *, startup_timeout: float = 120):
        self.config = config
        self.startup_timeout = startup_timeout

    def _json(self, origin, path, token=None, timeout=4):
        # Local requests must not use a system proxy or follow redirects with credentials.
        try:
            with httpx.Client(trust_env=False, follow_redirects=False, timeout=timeout) as client:
                headers = {"Authorization": "Bearer " + token} if token else {}
                response = client.get(origin + path, headers=headers)
                if len(response.content) > 2 * 1024 * 1024:
                    return response.status_code, None
                try:
                    data = response.json()
                except ValueError:
                    data = None
                return response.status_code, data if isinstance(data, dict) else None
        except httpx.HTTPError:
            return None, None

    @staticmethod
    def _port_open(port):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            return False

    def _token(self):
        try:
            token = (Path(self.config.data_dir) / "access-token.txt").read_text("utf-8").strip()
            return token if 32 <= len(token) <= 4096 and token.isascii() and token.isprintable() else None
        except (OSError, UnicodeError):
            return None

    def _pairing(self):
        try:
            value = json.loads(self.config.pairing_path.read_text("utf-8-sig"))
            return value if isinstance(value, dict) else None
        except (OSError, ValueError):
            return None

    def _comfy_ready(self):
        code, data = self._json(self.config.comfy_url, "/system_stats")
        return code == 200 and data is not None and isinstance(data.get("system"), dict) and isinstance(data.get("devices"), list)

    def _bridge_identity(self):
        code, data = self._json(self.config.bridge_url, "/health")
        return code in {200, 503} and data is not None and data.get("service") == "compositor-local-bridge" and data.get("protocolVersion") == 1

    def _bridge_parameters_match(self):
        """Do not silently reuse a bridge that points at a different ComfyUI or data root."""
        if os.name != "nt":
            return None
        script = (f"$c=Get-NetTCPConnection -State Listen -LocalPort {self.config.bridge_port} -ErrorAction Stop | Select-Object -First 1; "
                  "$p=Get-CimInstance Win32_Process -Filter ('ProcessId='+$c.OwningProcess); "
                  "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $OutputEncoding=[Console]::OutputEncoding; "
                  "$p.CommandLine | ConvertTo-Json -Compress")
        try:
            completed = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                                       capture_output=True, timeout=10, creationflags=_hidden())
            if completed.returncode:
                return None
            command = json.loads(completed.stdout.decode("utf-8-sig"))
            if not isinstance(command, str):
                return None
            shell = ctypes.WinDLL("shell32")
            shell.CommandLineToArgvW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]
            shell.CommandLineToArgvW.restype = ctypes.POINTER(ctypes.c_wchar_p)
            count = ctypes.c_int()
            pointer = shell.CommandLineToArgvW(command, ctypes.byref(count))
            if not pointer:
                return None
            try:
                args = [pointer[i] for i in range(count.value)]
            finally:
                kernel = ctypes.WinDLL("kernel32")
                kernel.LocalFree.argtypes = [ctypes.c_void_p]
                kernel.LocalFree(pointer)
            def argument(name):
                return args[args.index(name) + 1]
            return (argument("-m") == "bridge" and "serve" in args
                    and Path(argument("--data-dir")).resolve() == Path(self.config.data_dir).resolve()
                    and argument("--backend") == "comfyui"
                    and argument("--comfy-url").rstrip("/") == self.config.comfy_url
                    and argument("--host") == "0.0.0.0")
        except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
            return None

    def _network_check(self):
        try:
            adapters = discover_ipv4()
        except NetworkDiscoveryError as error:
            return False, str(error)
        match = next((a for a in adapters if a["address"] == self.config.lan_address and not a["virtual"]), None)
        if not match:
            return False, "配置中的地址不在当前物理网卡上。请打开设置，重新选择 Wi-Fi 或以太网地址。"
        return True, f"{match['name']} · {self.config.lan_address}"

    def status(self):
        config = self.config
        result = {"ready": False, "summary": "尚未就绪", "checks": [], "base_url": config.base_url,
                  "pairing_path": str(config.pairing_path), "logs_dir": str(config.logs_dir)}
        def check(name, state, message):
            result["checks"].append({"name": name, "state": state, "message": message})
        try:
            config.validate()
        except ValueError as error:
            check("本机设置", "error", str(error))
            result["summary"] = "请先完成本机设置"
            return result
        network_ok, message = self._network_check()
        check("局域网地址", "ok" if network_ok else "error", message)
        comfy_ok = self._comfy_ready()
        check("ComfyUI", "ok" if comfy_ok else "error" if self._port_open(config.comfy_port) else "stopped",
              "本机服务已响应" if comfy_ok else "端口被占用或 ComfyUI 尚未完成启动" if self._port_open(config.comfy_port) else "尚未启动，点击启动服务即可准备")
        identity = self._bridge_identity()
        token = self._token()
        authenticated = False
        if identity and token:
            code, caps = self._json(config.bridge_url, "/v1/capabilities", token)
            authenticated = code == 200 and caps is not None and caps.get("protocolVersion") == 1 and caps.get("backend") == "comfyui" and caps.get("isSimulation") is False
        else:
            caps = None
        parameters = self._bridge_parameters_match() if authenticated else None
        if authenticated and parameters is True:
            check("桥接服务", "ok", "已连接到本机数据目录和指定的 ComfyUI")
        elif authenticated:
            check("桥接服务", "error", "已运行服务的参数与设置不符，或无法核对进程。请检查启动参数；启动器不会替换已有进程。")
        elif identity:
            check("桥接服务", "error", "已有桥接与此数据目录的配对或后端不一致，请检查数据目录。")
        elif self._port_open(config.bridge_port):
            check("桥接服务", "error", "桥接端口被其他程序占用，请选择空闲端口。")
        else:
            check("桥接服务", "stopped", "尚未启动，点击启动服务即可准备")
        backend_ok = False
        if authenticated:
            code, backend = self._json(config.bridge_url, "/v1/backend/status", token, timeout=12)
            backend_ok = (code == 200 and backend is not None and backend.get("ok") is True
                          and backend.get("backend") == "comfyui" and backend.get("isSimulation") is False)
            if backend_ok:
                check("AI 模型", "ok", "模型和节点已就绪，可进行真实生成")
            else:
                missing = []
                if backend:
                    for key in ("missingModels", "missingNodes", "invalidInputs"):
                        values = backend.get(key, [])
                        if isinstance(values, list):
                            missing.extend(str(value)[:150] for value in values[:8])
                check("AI 模型", "error", "缺少或不兼容：" + "、".join(missing) if missing else "AI 后端尚未就绪，请检查 ComfyUI 日志和模型路径")
            check("候选清理", "ok" if caps.get("jobDeletionSupported") is True else "warning",
                  "支持删除已结束的候选任务" if caps.get("jobDeletionSupported") is True else "此桥接版本暂不支持远端候选删除，请更新后再使用")
        pairing = self._pairing()
        pairing_ok = bool(token and pairing and pairing.get("protocolVersion") == 1 and pairing.get("backend") == "comfyui"
                          and pairing.get("accessToken") == token and pairing.get("baseUrl") == config.base_url)
        check("设备配对", "ok" if pairing_ok else "warning",
              "配对文件与当前地址一致" if pairing_ok else "点击启动服务会准备当前地址的配对文件；地址改变后请在 iPad 重新导入")
        lan_ok = False
        if network_ok and authenticated:
            code, health = self._json(config.base_url, "/health")
            lan_ok = code == 200 and health is not None and health.get("service") == "compositor-local-bridge"
            check("连接入口", "ok" if lan_ok else "error", "本机可访问局域网入口。iPad 还需连接同一网络并允许本地网络访问。" if lan_ok else "本机无法访问此局域网入口，请检查监听地址和网络设置")
        result["ready"] = all((network_ok, comfy_ok, authenticated, parameters is True, backend_ok, pairing_ok, lan_ok))
        result["summary"] = "可以连接 iPad" if result["ready"] else "还有项目需要处理，请查看下方状态"
        return result

    def _check_start(self):
        try:
            self.config.validate()
        except ValueError as error:
            raise LauncherError(str(error)) from None
        ok, message = self._network_check()
        if not ok:
            raise LauncherError(message)
        if not Path(self.config.bridge_python).is_file():
            raise LauncherError("找不到桥接 Python，请在设置中选择已安装依赖的 Python 环境。")
        # A copied/malformed pairing must not rotate or replace an existing credential.
        root = Path(self.config.data_dir)
        if (root / "access-token.txt").exists() and self._token() is None:
            raise LauncherError("原数据目录的配对凭据无法读取，请先修复该文件；不会生成替代凭据。")
        pairing = self._pairing()
        if self.config.pairing_path.exists():
            if not pairing or pairing.get("accessToken") != self._token() or pairing.get("backend") != "comfyui" or pairing.get("protocolVersion") != 1:
                raise LauncherError("现有配对文件与数据目录不一致，请选择原来的真实后端数据目录。")
        if (root / "jobs.sqlite3").exists() and self._token() is None:
            raise LauncherError("已有任务数据缺少原配对凭据，请恢复原凭据后再启动。")

    def _state(self):
        try:
            value = json.loads((Path(self.config.data_dir) / "launcher-state.json").read_text("utf-8"))
            if not isinstance(value, dict):
                raise ValueError()
            return value
        except FileNotFoundError:
            return {}
        except (OSError, ValueError):
            raise LauncherError("上次的启动记录无法读取。请先核对现有进程和日志，避免重复启动。") from None

    def _save_state(self, state):
        path = Path(self.config.data_dir) / "launcher-state.json"
        temporary = path.with_suffix(".tmp")
        try:
            temporary.write_text(json.dumps(state, indent=2), "utf-8")
            temporary.replace(path)
        except OSError:
            raise LauncherError("无法写入启动记录，请检查数据目录权限；若进程已启动，请先检查服务和日志。") from None

    def _intent(self, name):
        # Persist uncertainty before spawning. Even a helper timeout after spawning
        # must not make the next button click launch another GPU process.
        state = self._state()
        state[name] = {"phase": "launching", "configKey": self._config_key(name), "startedAt": time.time()}
        self._save_state(state)

    def _record(self, name, pid):
        state = self._state()
        state[name] = {"phase": "unverified", "pid": pid, "startedAt": time.time(), "identity": None,
                       "configKey": self._config_key(name)}
        self._save_state(state)
        stamp = _process_stamp(pid)
        if stamp is None:
            raise LauncherError(f"{name} 已请求启动，但进程身份尚未核对。请检查服务和日志，暂不重复启动。")
        state[name].update(phase="verified", identity=stamp)
        self._save_state(state)

    def _config_key(self, name):
        config = self.config
        values = [config.bridge_python, config.data_dir, str(config.bridge_port), str(config.comfy_port)]
        if name == "ComfyUI":
            values.extend([config.comfy_install, config.models_dir, config.runtime_dir])
        return hashlib.sha256(json.dumps(values).encode("utf-8")).hexdigest()

    def _pending_process(self, name):
        record = self._state().get(name, {})
        if isinstance(record, dict) and record.get("phase") == "launching":
            raise LauncherError(f"上次 {name} 的启动结果尚未确认。请先检查服务和日志，避免重复启动。")
        if not isinstance(record, dict) or not _alive(record.get("pid")):
            return False
        if not record.get("identity"):
            raise LauncherError(f"先前的 {name} 进程仍存在，但身份尚未确认。请先检查服务和日志，暂不重复启动。")
        identity = _process_stamp(record["pid"])
        if identity is None:
            raise LauncherError(f"无法核对先前的 {name} 进程。请检查日志与进程权限，避免重复启动。")
        if identity != record.get("identity"):
            return False
        if self._config_key(name) != record.get("configKey"):
            raise LauncherError(f"先前的 {name} 仍在使用旧设置。请结束旧实例后应用新路径或端口。")
        return True

    def _wait_ready(self, name, ready):
        deadline = time.monotonic() + self.startup_timeout
        while time.monotonic() < deadline:
            if ready():
                return
            record = self._state().get(name, {})
            if not _alive(record.get("pid")):
                raise LauncherError(f"{name} 启动后已退出，请打开日志查看原因。")
            time.sleep(0.5)
        raise LauncherError(f"{name} 仍在准备或没有响应，请查看日志，稍后再次检查。现有进程不会被重复启动。")

    def _launch_comfy(self):
        config = self.config
        install = Path(config.comfy_install)
        if not (install / "main.py").is_file() or not (install / ".venv" / "Scripts" / "python.exe").is_file():
            raise LauncherError("ComfyUI 安装目录需要包含 main.py 和 .venv\\Scripts\\python.exe，请选择现有安装目录。")
        if not Path(config.models_dir).is_dir():
            raise LauncherError("找不到模型文件夹，请选择现有共享模型目录。")
        env = os.environ.copy()
        env.pop("SSLKEYLOGFILE", None)
        env["PYTHONIOENCODING"] = "utf-8"
        self._intent("ComfyUI")
        try:
            completed = subprocess.run([config.bridge_python, str(BRIDGE_ROOT / "tools" / "start_local_comfy.py"),
                                       "--install", config.comfy_install, "--models", config.models_dir,
                                       "--runtime", config.runtime_dir, "--port", str(config.comfy_port)],
                                      cwd=BRIDGE_ROOT, env=env, capture_output=True, timeout=20, creationflags=_hidden())
            if completed.returncode:
                raise LauncherError("ComfyUI 未能启动，请检查安装和缓存目录；可以打开 ComfyUI 缓存目录查看日志。")
            response = json.loads(completed.stdout.decode("utf-8"))
            pid = response["pid"]
            if type(pid) is not int or pid <= 0:
                raise ValueError()
            self._record("ComfyUI", pid)
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
            raise LauncherError("无法启动 ComfyUI，请检查 Python 与安装路径。") from None

    def _launch_bridge(self):
        config = self.config
        config.logs_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        env = os.environ.copy()
        env.pop("SSLKEYLOGFILE", None)
        env["PYTHONIOENCODING"] = "utf-8"
        with (config.logs_dir / f"bridge-{stamp}.stdout.log").open("ab") as out, (config.logs_dir / f"bridge-{stamp}.stderr.log").open("ab") as err:
            self._intent("桥接")
            try:
                process = subprocess.Popen([config.bridge_python, "-m", "bridge", "serve", "--data-dir", config.data_dir,
                                            "--backend", "comfyui", "--comfy-url", config.comfy_url,
                                            "--host", "0.0.0.0", "--port", str(config.bridge_port)],
                                           cwd=BRIDGE_ROOT, env=env, stdout=out, stderr=err, creationflags=_hidden())
            except OSError:
                # Popen failed before creating a child; allow corrected settings to retry.
                # Unknown helper outcomes and post-spawn failures keep their intent.
                state = self._state()
                state.pop("桥接", None)
                self._save_state(state)
                raise LauncherError("桥接启动失败，请检查 Python 路径和依赖安装。") from None
        self._record("桥接", process.pid)

    def _verify_bridge(self):
        token = self._token()
        if not self._bridge_identity() or not token:
            raise LauncherError("桥接端口已被占用，或无法读取原配对凭据。请先检查现有服务。")
        code, caps = self._json(self.config.bridge_url, "/v1/capabilities", token)
        if code != 200 or not caps or caps.get("protocolVersion") != 1 or caps.get("backend") != "comfyui" or caps.get("isSimulation") is not False:
            raise LauncherError("现有桥接不属于所选数据目录，或正在使用模拟后端。请检查设置；不会替换已有服务。")
        if self._bridge_parameters_match() is not True:
            raise LauncherError("无法确认现有桥接的启动参数与设置一致。请检查服务是否使用所选数据目录和 ComfyUI 端口。")

    def _write_pairing(self):
        expected = {"protocolVersion": 1, "baseUrl": self.config.base_url,
                    "accessToken": self._token(), "backend": "comfyui"}
        if self._pairing() == expected:
            return False
        # Service authentication has already verified that this is the original token.
        if not expected["accessToken"]:
            raise LauncherError("桥接没有准备好配对凭据，请检查日志。")
        path = self.config.pairing_path
        temporary = path.with_name("pairing.pending.json")
        try:
            temporary.write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n", "utf-8")
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
        return True

    def start(self):
        self._check_start()
        with startup_lock():
            # Check bridge conflicts BEFORE launching the GPU process or touching pairing.
            if self._port_open(self.config.bridge_port):
                self._verify_bridge()
            if self._port_open(self.config.comfy_port) and not self._comfy_ready():
                raise LauncherError("ComfyUI 端口被其他程序占用或尚未响应，请先检查现有进程。")
            Path(self.config.data_dir).mkdir(parents=True, exist_ok=True)
            if not self._comfy_ready():
                if not self._pending_process("ComfyUI"):
                    self._launch_comfy()
                self._wait_ready("ComfyUI", self._comfy_ready)
            if not self._port_open(self.config.bridge_port):
                if not self._pending_process("桥接"):
                    self._launch_bridge()
                self._wait_ready("桥接", self._bridge_identity)
            self._verify_bridge()
            changed = self._write_pairing()
            result = self.status()
            if changed:
                result["checks"].append({"name": "配对更新", "state": "warning", "message": "配对文件已更新为当前地址。请将它私下传到 iPad 并重新导入，原令牌和任务保留。"})
            return result

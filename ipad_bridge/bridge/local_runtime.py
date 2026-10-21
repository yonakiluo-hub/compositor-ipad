"""Bind HTTP-reported ComfyUI arguments to an observable local process.

No server-provided path or command is executed. This check deliberately fails
closed when the OS cannot identify the listener; it supports a local ComfyUI
process, not a proxy, container-forwarded port or remote inference service.
"""
from __future__ import annotations

import math
import time
from pathlib import Path
from urllib.parse import urlsplit

import psutil


class LocalRuntimeError(ValueError):
    """Public-safe diagnostic without arguments, paths or artwork information."""


def _listener_pid(port: int, addresses: set[str]) -> int:
    pids = set()
    for connection in psutil.net_connections(kind="tcp"):
        if connection.status != psutil.CONN_LISTEN or not connection.laddr:
            continue
        address, bound_port = connection.laddr[:2]
        if bound_port != port:
            continue
        if address in {"0.0.0.0", "::"}:
            raise LocalRuntimeError("The ComfyUI listener must be restricted to loopback.")
        if address not in addresses:
            continue
        if type(connection.pid) is not int or connection.pid <= 0:
            raise LocalRuntimeError("The operating system could not identify the local ComfyUI listener.")
        pids.add(connection.pid)
    if len(pids) != 1:
        raise LocalRuntimeError("A unique local ComfyUI listener could not be verified.")
    return pids.pop()


def _start_time(process) -> float:
    value = process.create_time()
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or not 0 < value <= time.time() + 1):
        raise LocalRuntimeError("The local ComfyUI process start time could not be verified.")
    return float(value)


def attest_local_runtime(base_url: str, server_argv: list[str]) -> dict:
    """Return only the PID and Unix start time of the verified loopback listener.

    The process must run the exact main.py and full argument suffix reported by
    ComfyUI. Rechecking the listener and start time closes the common restart/PID
    reuse race during inspection. The caller must still verify expected model
    roots and safety flags and compare dependency timestamps with ``startedAt``.
    """
    try:
        parsed = urlsplit(base_url)
        hostname = parsed.hostname
        if (parsed.scheme not in {"http", "https"} or hostname not in {"127.0.0.1", "localhost", "::1"}
                or parsed.username is not None or parsed.password is not None
                or parsed.path not in {"", "/"} or parsed.query or parsed.fragment):
            raise LocalRuntimeError("ComfyUI runtime verification requires a loopback HTTP origin.")
        port = parsed.port if parsed.port is not None else (443 if parsed.scheme == "https" else 80)
        if not 1 <= port <= 65535:
            raise LocalRuntimeError("The local ComfyUI port is invalid.")
        if (not isinstance(server_argv, list) or not server_argv
                or any(not isinstance(value, str) or "\x00" in value for value in server_argv)):
            raise LocalRuntimeError("ComfyUI did not report verifiable startup arguments.")
        reported_main = Path(server_argv[0])
        if not reported_main.is_absolute() or reported_main.name.lower() != "main.py":
            raise LocalRuntimeError("ComfyUI did not report an absolute main.py entry point.")
        reported_main = reported_main.resolve(strict=True)
        if not reported_main.is_file():
            raise LocalRuntimeError("The local ComfyUI entry point is unavailable.")
        addresses = {"127.0.0.1", "::1"} if hostname == "localhost" else {hostname}
        pid = _listener_pid(port, addresses)
        process = psutil.Process(pid)
        started = _start_time(process)
        command = process.cmdline()
        if not isinstance(command, list) or any(not isinstance(value, str) for value in command):
            raise LocalRuntimeError("The local ComfyUI startup arguments could not be read.")
        matches = []
        for index, argument in enumerate(command):
            candidate = Path(argument)
            if not candidate.is_absolute() or candidate.name.lower() != "main.py":
                continue
            if candidate.resolve(strict=True) == reported_main and command[index:] == server_argv:
                matches.append(index)
        if len(matches) != 1:
            raise LocalRuntimeError("The local listener does not match ComfyUI's reported startup arguments.")
        if _listener_pid(port, addresses) != pid or _start_time(psutil.Process(pid)) != started:
            raise LocalRuntimeError("The local ComfyUI process changed during verification. Retry after restart.")
        return {"pid": pid, "startedAt": started}
    except LocalRuntimeError:
        raise
    except (psutil.Error, OSError, ValueError, TypeError, AttributeError, IndexError):
        raise LocalRuntimeError("The local ComfyUI process could not be verified. Check local process permissions and restart if needed.") from None

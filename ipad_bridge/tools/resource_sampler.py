"""Best-effort local resource samples for evaluation, never generation admission.

GPU memory is the sum reported for all visible devices, including other apps.
The optional process RSS belongs only to the explicitly supplied PID; this module
does not discover processes or walk child processes. No paths or command output
are included in reports.
"""
from __future__ import annotations

import math
import os
import subprocess
import threading
from collections.abc import Callable


class ResourceSampler:
    def __init__(self, pid: int | None = None, interval_seconds: float = 0.5,
                 sample_provider: Callable[[], dict] | None = None):
        if not isinstance(interval_seconds, (int, float)) or isinstance(interval_seconds, bool) or not math.isfinite(interval_seconds) or interval_seconds <= 0:
            raise ValueError("The sampling interval must be positive and finite.")
        if pid is not None and (type(pid) is not int or pid <= 0):
            raise ValueError("The optional process ID must be a positive integer.")
        self.pid = pid
        self.interval_seconds = float(interval_seconds)
        self._provider = sample_provider or self.single_measure
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._thread = None
        self._attempts = 0
        self._samples = 0
        self._gpu_samples = 0
        self._peaks = {}

    def single_measure(self) -> dict:
        """Collect one sweep. Missing tools, denied PIDs and exited processes are OK."""
        result = {}
        try:
            completed = subprocess.run(
                ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=2, check=False,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0,
            )
            if completed.returncode == 0:
                values = [float(line.strip()) for line in completed.stdout.splitlines() if line.strip()]
                if values and all(math.isfinite(value) and value >= 0 for value in values):
                    result["deviceUsedMiB"] = sum(values)
        except (OSError, subprocess.SubprocessError, ValueError, UnicodeError):
            pass
        try:
            import psutil
            result["systemUsedMiB"] = psutil.virtual_memory().used / (1024 * 1024)
            if self.pid is not None:
                try:
                    result["processRssMiB"] = psutil.Process(self.pid).memory_info().rss / (1024 * 1024)
                except (psutil.Error, OSError):
                    pass
        except (ImportError, OSError):
            pass
        return result

    def sample_once(self):
        """One best-effort measurement, also useful for deterministic harnesses."""
        try:
            measured = self._provider()
        except Exception:
            measured = {}
        values = {}
        for key in ("deviceUsedMiB", "processRssMiB", "systemUsedMiB"):
            value = measured.get(key) if isinstance(measured, dict) else None
            if key == "processRssMiB" and self.pid is None:
                continue
            if isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0:
                values[key] = float(value)
        with self._lock:
            self._attempts += 1
            if values:
                self._samples += 1
                self._gpu_samples += "deviceUsedMiB" in values
                for key, value in values.items():
                    self._peaks[key] = max(self._peaks.get(key, 0), value)

    def _run(self):
        while not self._stop.is_set():
            self.sample_once()
            if self._stop.wait(self.interval_seconds):
                break

    def start(self):
        """Start this single measurement window; repeated calls are harmless."""
        if self._thread is None and not self._stop.is_set():
            self._thread = threading.Thread(target=self._run, name="evaluation-resource-sampler", daemon=True)
            self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        if self._thread is not None and self._thread is not threading.current_thread():
            # A timed-out or misbehaving sample must not indefinitely delay a result.
            self._thread.join(timeout=2.25)

    def report(self) -> dict:
        with self._lock:
            result = {
                "status": "sampled" if self._samples else "unavailable",
                "intervalSeconds": self.interval_seconds,
                "sampleCount": self._samples,
                "attemptCount": self._attempts,
                "gpuSampleCount": self._gpu_samples,
                "gpuStatus": "sampled" if self._gpu_samples else "unavailable",
                "sampledPeakDeviceUsedMiB": self._peaks.get("deviceUsedMiB"),
                "sampledPeakSystemUsedMiB": self._peaks.get("systemUsedMiB"),
                "deviceAggregation": "sum_of_visible_gpus",
                "limitations": "Periodic samples may miss short peaks. GPU values include all apps on all visible devices, not a CUDA allocation peak. Process RSS covers only the explicitly supplied PID, without children; system memory includes other apps. Measurements are not per-job allocations.",
            }
            if self.pid is not None:
                result["sampledPeakProcessRssMiB"] = self._peaks.get("processRssMiB")
            return result

    def __enter__(self):
        return self.start()

    def __exit__(self, *_):
        self.stop()

import json
import subprocess
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from tools.resource_sampler import ResourceSampler


def test_deterministic_samples_record_peaks_and_safe_limits():
    samples = iter([
        {"deviceUsedMiB": 500, "processRssMiB": 100, "systemUsedMiB": 1000},
        {"deviceUsedMiB": 450, "processRssMiB": 110, "systemUsedMiB": 900},
        {"deviceUsedMiB": 600, "processRssMiB": 90, "systemUsedMiB": 1200},
    ])
    sampler = ResourceSampler(pid=123, sample_provider=lambda: next(samples))
    for _ in range(3):
        sampler.sample_once()
    result = sampler.report()
    assert result["status"] == "sampled"
    assert result["sampleCount"] == result["gpuSampleCount"] == 3
    assert result["sampledPeakDeviceUsedMiB"] == 600
    assert result["sampledPeakProcessRssMiB"] == 110
    assert result["sampledPeakSystemUsedMiB"] == 1200
    assert "not a CUDA allocation peak" in result["limitations"]
    assert "123" not in json.dumps(result)


def test_missing_gpu_is_explicit_even_when_host_metrics_are_available():
    sampler = ResourceSampler(sample_provider=lambda: {"systemUsedMiB": 1024, "processRssMiB": 20})
    sampler.sample_once()
    result = sampler.report()
    assert result["status"] == "sampled"
    assert result["gpuStatus"] == "unavailable"
    assert result["sampledPeakDeviceUsedMiB"] is None
    assert result["sampledPeakSystemUsedMiB"] == 1024
    assert "sampledPeakProcessRssMiB" not in result


def test_unavailable_and_invalid_measurements_never_claim_zero_peak():
    sampler = ResourceSampler(sample_provider=lambda: {"deviceUsedMiB": float("nan"), "systemUsedMiB": -1})
    sampler.sample_once()
    result = sampler.report()
    assert result["status"] == "unavailable"
    assert result["sampleCount"] == 0
    assert result["attemptCount"] == 1
    assert result["sampledPeakDeviceUsedMiB"] is None
    assert result["sampledPeakSystemUsedMiB"] is None


def test_provider_failure_is_non_fatal_and_does_not_expose_details():
    provider = Mock(side_effect=OSError("private path and command details"))
    sampler = ResourceSampler(sample_provider=provider)
    sampler.sample_once()
    assert sampler.report()["status"] == "unavailable"
    assert "private" not in json.dumps(sampler.report())


def test_single_measure_uses_bounded_hidden_gpu_command(monkeypatch):
    run = Mock(return_value=SimpleNamespace(returncode=0, stdout="100\n200\n"))
    monkeypatch.setattr(subprocess, "run", run)
    sampler = ResourceSampler()
    result = sampler.single_measure()
    assert result["deviceUsedMiB"] == 300
    args, kwargs = run.call_args
    assert args[0] == ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"]
    assert kwargs["timeout"] == 2
    assert kwargs["check"] is False
    assert kwargs["creationflags"] == getattr(subprocess, "CREATE_NO_WINDOW", 0)


@pytest.mark.parametrize("error", [FileNotFoundError(), subprocess.TimeoutExpired("nvidia-smi", 2)])
def test_missing_or_timed_out_gpu_tool_still_returns_host_sample(monkeypatch, error):
    monkeypatch.setattr(subprocess, "run", Mock(side_effect=error))
    result = ResourceSampler().single_measure()
    assert "deviceUsedMiB" not in result
    assert "processRssMiB" not in result


def test_context_manager_stops_on_generation_error_without_swallowing_it(monkeypatch):
    sampler = ResourceSampler()
    sampler.start = Mock(return_value=sampler)
    sampler.stop = Mock()
    with pytest.raises(RuntimeError, match="generation"):
        with sampler:
            raise RuntimeError("generation")
    sampler.start.assert_called_once_with()
    sampler.stop.assert_called_once_with()


def test_stop_has_bounded_join_without_timing_assumptions():
    sampler = ResourceSampler()
    thread = Mock()
    sampler._thread = thread
    sampler.stop()
    thread.join.assert_called_once_with(timeout=2.25)


@pytest.mark.parametrize("interval", [0, -1, float("nan"), True])
def test_invalid_interval_is_rejected(interval):
    with pytest.raises(ValueError):
        ResourceSampler(interval_seconds=interval)

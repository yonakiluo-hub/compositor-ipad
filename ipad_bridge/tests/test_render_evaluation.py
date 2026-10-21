import hashlib
import json

import pytest

from tools.evaluate_painting import prepare_suite
from tools.render_evaluation import read_suite, render


def finished_case(root, preset, elapsed, status=202):
    suite = prepare_suite(root, preset, (768,), (42,))
    case_id = suite["cases"][0]["id"]
    folder = root / case_id
    content = (folder / "input.png").read_bytes()
    (folder / "result.png").write_bytes(content)
    (folder / "composite.png").write_bytes(content)
    report = {"presetId": preset, "seed": 42, "state": "succeeded", "firstSubmitStatus": status,
              "elapsedSeconds": elapsed, "jobId": "private-job-id", "privatePath": "private-machine-path",
              "execution": {"presetVersion": "1.0.0", "graphHash": "a" * 64, "dependencyFingerprint": "b" * 64,
                            "sourceSha256": "c" * 64, "privatePath": "execution-private-path"},
              "resourceMeasurement": {"sampledPeakDeviceUsedMiB": 15000, "private": "not-exported"},
              "verification": {"sha256": hashlib.sha256(content).hexdigest(), "width": 768, "height": 768,
                               "sourceAndCropMatch": True, "maskZeroAlphaZero": True, "alphaWithinMask": True,
                               "compositeOutsideMaskUnchanged": True, "maskApplied": True, "alphaMode": "straight"}}
    (folder / "report.json").write_text(json.dumps(report), "utf-8")
    return case_id, folder


def test_gallery_maps_same_cases_to_model_columns_and_excludes_recovery_timing(tmp_path):
    first = tmp_path / "klein"
    second = tmp_path / "qwen"
    case_id, _ = finished_case(first, "paint-edit-v1", 20)
    finished_case(second, "qwen21-edit-v1", .2, status=200)
    output = tmp_path / "private report.html"
    summary = render([read_suite(first), read_suite(second)], output)
    page = output.read_text("utf-8")
    assert page.count('<section data-scenario=') == 12
    assert "Klein 4B" in page and "Qwen 2.1" in page
    assert "待生成" in page and "显示原始输入" in page
    assert case_id in page
    assert "恢复查询等待 0.20 秒" in page
    assert summary["models"][0]["freshTimingSamples"] == 1
    assert summary["models"][0]["byInputSize"][0]["freshEndToEndSeconds"] == {"min": 20, "p50": 20, "max": 20}
    assert summary["models"][0]["executionProvenance"][0]["sourceSha256"] == "c" * 64
    assert summary["models"][1]["freshTimingSamples"] == 0
    assert summary["models"][1]["recoveryResults"] == 1
    exported = output.with_suffix(".summary.json").read_text("utf-8")
    assert "private-job-id" not in exported
    assert "private-machine-path" not in exported
    assert "execution-private-path" not in exported
    assert str(tmp_path) not in exported
    assert "not-exported" not in page


def test_gallery_escapes_labels_and_quotes_file_urls(tmp_path):
    root = tmp_path / "images & other"
    finished_case(root, "paint-edit-v1", 4)
    index = json.loads((root / "suite.json").read_text("utf-8"))
    index["cases"][0]["subject"] = '<img src=x onerror="bad">'
    (root / "suite.json").write_text(json.dumps(index), "utf-8")
    output = tmp_path / "report.html"
    render([read_suite(root)], output)
    page = output.read_text("utf-8")
    assert '<img src=x onerror="bad">' not in page
    assert "&lt;img src=x onerror=&quot;bad&quot;&gt;" in page
    assert "images%20%26%20other" in page


def test_gallery_rejects_traversal_and_duplicate_model_columns(tmp_path):
    root = tmp_path / "suite"
    prepare_suite(root, "paint-edit-v1", (768,), (42,))
    loaded = read_suite(root)
    with pytest.raises(ValueError, match="distinct"):
        render([loaded, loaded], tmp_path / "report.html")
    index = json.loads((root / "suite.json").read_text("utf-8"))
    index["cases"][0]["id"] = "../secrets"
    (root / "suite.json").write_text(json.dumps(index), "utf-8")
    with pytest.raises(ValueError, match="identifier"):
        read_suite(root)


def test_gallery_marks_mismatched_output_digest_as_unverified(tmp_path):
    case_id, folder = finished_case(tmp_path, "paint-edit-v1", 3)
    (folder / "result.png").write_bytes(b"changed")
    loaded = read_suite(tmp_path)
    assert loaded["cases"][case_id]["state"] == "invalid_result"
    summary = render([loaded], tmp_path / "report.html")
    assert summary["models"][0]["counts"]["invalid_result"] == 1
    assert summary["models"][0]["freshTimingSamples"] == 0

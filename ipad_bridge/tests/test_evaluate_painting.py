import io
import json
from pathlib import Path

import httpx
import pytest
from PIL import Image

from tools.evaluate_painting import completed_report, fixture, prepare_suite, run_case
from bridge.images import make_result


def test_suite_matrix_and_resume_preserve_request_bytes(tmp_path):
    suite = prepare_suite(tmp_path, "paint-edit-v1")
    assert len(suite["cases"]) == 48  # Four tasks, three subjects, two sizes and two seeds.
    before = {case["id"]: (tmp_path / case["id"] / "metadata.json").read_bytes() for case in suite["cases"]}
    assert prepare_suite(tmp_path, "paint-edit-v1") == suite
    assert all((tmp_path / key / "metadata.json").read_bytes() == value for key, value in before.items())
    request_ids = {json.loads(value)["clientRequestId"] for value in before.values()}
    assert len(request_ids) == 48
    prompts = [json.loads(value)["prompt"] for value in before.values()]
    assert any("two-value" in prompt for prompt in prompts)
    assert any("four-value" in prompt for prompt in prompts)
    assert suite["qualityAdmission"] == "pending_human_review"


def test_resume_refuses_changed_pixels_and_different_configuration(tmp_path):
    suite = prepare_suite(tmp_path, "qwen21-edit-v1", (768,), (123,))
    with pytest.raises(ValueError, match="configuration"):
        prepare_suite(tmp_path, "qwen21-turbo-edit-v1", (768,), (123,))
    path = tmp_path / suite["cases"][0]["id"] / "input.png"
    path.write_bytes(path.read_bytes() + b"changed")
    with pytest.raises(ValueError, match="changed"):
        prepare_suite(tmp_path, "qwen21-edit-v1", (768,), (123,))


def test_local_repair_fixture_preserves_unmasked_source_and_soft_coverage():
    image, mask = fixture("local_repair", "portrait", 768)
    source = Image.open(io.BytesIO(image))
    coverage = Image.open(io.BytesIO(mask))
    assert source.mode == "RGBA"
    assert coverage.mode == "L"
    assert coverage.size == source.size == (768, 768)
    assert {value for value, count in enumerate(coverage.histogram()) if count} == {0, 128, 255}
    assert source.getpixel((384, 384)) == (255, 0, 255, 255)
    assert coverage.getpixel((384, 384)) == 255
    assert coverage.getpixel((0, 0)) == 0


def test_failure_report_retains_job_and_does_not_request_results(tmp_path):
    suite = prepare_suite(tmp_path, "paint-edit-v1", (768,), (123,))
    requests = []
    def handler(request):
        requests.append((request.method, request.url.path))
        return httpx.Response(202, json={"jobId": "existing-job", "state": "failed", "error": {"code": "out_of_memory", "message": "No fallback was applied."}})
    with httpx.Client(transport=httpx.MockTransport(handler), base_url="http://test") as client:
        report = run_case(client, tmp_path / suite["cases"][0]["id"], 1)
    assert report["jobId"] == "existing-job"
    assert report["state"] == "failed"
    assert report["error"]["code"] == "out_of_memory"
    assert requests == [("POST", "/v1/jobs")]
    assert report["resourceMeasurement"] == "not_collected"


def test_qwen_turbo_uses_official_nonuniform_schedule_and_separate_source_alpha():
    presets = Path(__file__).parents[1] / "bridge" / "presets"
    graph = json.loads((presets / "qwen21-turbo-edit-v1.json").read_text("utf-8"))
    sigmas = [float(v) for v in graph["17"]["inputs"]["sigmas"].split(",")]
    assert sigmas == [1, .978453, .95418, .926626, .89508, .845148, .704534, .414568, 0]
    assert graph["7"]["inputs"]["images.image_1"] == ["3", 0]
    assert graph["3"] == {"class_type": "JoinImageWithAlpha", "inputs": {"image": ["1", 0], "alpha": ["1", 1]}}
    # Only the uploaded source image is loaded. The iPad selection stays in the bridge.
    assert sum(n["class_type"] == "LoadImage" for n in graph.values()) == 1
    assert not any("mask" in key.lower() for node in graph.values() for key in node["inputs"])


def test_model_half_alpha_and_half_selection_return_quarter_alpha_once():
    # Simulated RGBA VAE output exercises the actual shared result processor.
    # It is an alpha-contract test, not a real Qwen GPU inference claim.
    generated = Image.new("RGBA", (3, 1), (180, 90, 45, 128))
    selection = Image.new("L", (3, 1))
    selection.putdata([0, 128, 255])
    def encoded(image):
        output = io.BytesIO()
        image.save(output, format="PNG")
        return output.getvalue()
    metadata = json.loads((Path(__file__).parents[1] / "examples" / "metadata.json").read_text("utf-8"))
    metadata.update(cropRect={"x": 73, "y": 91, "width": 3, "height": 1},
                    inputSize={"width": 3, "height": 1}, workflowPreset="qwen21-edit-v1")
    result = Image.open(io.BytesIO(make_result(encoded(generated), encoded(selection), metadata)))
    assert [result.getpixel((x, 0))[3] for x in range(3)] == [0, 64, 128]
    assert result.getpixel((1, 0))[:3] == (180, 90, 45)  # Straight RGB stays unpremultiplied.


def test_resume_keeps_completed_result_and_original_measurement(tmp_path, monkeypatch):
    from tools import evaluate_painting
    from test_render_evaluation import finished_case
    _, folder = finished_case(tmp_path / "suite", "paint-edit-v1", 123.5)
    before = (folder / "report.json").read_bytes()
    assert completed_report(folder)["elapsedSeconds"] == 123.5
    original_client = httpx.Client
    monkeypatch.setattr(evaluate_painting.httpx, "Client", lambda **kwargs: original_client(
        base_url="http://test", transport=httpx.MockTransport(lambda request: httpx.Response(200, json={
            "backend": "comfyui", "presets": [{"id": "paint-edit-v1", "enabled": True}],
        }))))
    monkeypatch.setattr(evaluate_painting, "read_pairing", lambda path: {
        "baseUrl": "http://test", "accessToken": "unused-in-test", "backend": "comfyui",
    })
    monkeypatch.setattr(evaluate_painting, "run_case", lambda *args: pytest.fail("Completed work must not be submitted again"))
    monkeypatch.setattr("sys.argv", ["evaluate_painting", "--run", "--output", str(tmp_path / "suite"),
                                     "--pairing", "unused", "--sizes", "768", "--seeds", "42", "--limit", "1"])
    assert evaluate_painting.main() == 0
    assert (folder / "report.json").read_bytes() == before
    (folder / "result.png").write_bytes(b"changed")
    assert completed_report(folder) is None

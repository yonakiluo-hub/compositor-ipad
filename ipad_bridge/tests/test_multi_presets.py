import asyncio
import copy
import json
import shutil
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from bridge.app import create_app
from bridge.comfy import ComfyBackend, ComfyError
from bridge.config import Settings
from bridge.identity import digest_json
from bridge.registry import PresetRegistry, RegistryError
from test_app import example


@pytest.fixture
def service_factory(tmp_path, monkeypatch):
    stack = ExitStack()
    number = 0

    async def freeze(backend, metadata):
        try:
            snapshot = backend.registry.freeze(metadata["workflowPreset"], metadata)
        except RegistryError as exc:
            raise ComfyError(str(exc), exc.code) from None
        snapshot["runtime"] = {"testDependency": "one"}
        snapshot["dependencyFingerprint"] = digest_json(snapshot["runtime"])
        return snapshot

    monkeypatch.setattr(ComfyBackend, "freeze", freeze)

    def start(**options):
        nonlocal number
        number += 1
        root = tmp_path / str(number)
        presets = root / "presets"
        source = Path(__file__).parents[1] / "bridge" / "presets"
        shutil.copytree(source, presets)
        manifest = json.loads((presets / "manifest.json").read_text("utf-8"))
        base = next(item for item in manifest["presets"] if item["id"] == "paint-edit-v1")
        other = copy.deepcopy(base)
        other.update(id="test-edit-v1", name="Experimental test edit", experimental=True)
        # Deliberately put experimental first: legacy clients still need Klein first.
        manifest["presets"] = [other, base]
        (presets / "manifest.json").write_text(json.dumps(manifest), "utf-8")
        settings = Settings(root / "data", backend="comfyui", preset_dir=presets,
                            start_worker=False, **options)
        app = create_app(settings)
        client = stack.enter_context(TestClient(app))
        headers = {"Authorization": "Bearer " + settings.token()}
        return client, app, headers, presets

    yield start
    stack.close()


def submit(client, headers, metadata=None):
    base, image, mask = example("paint-edit-v1")
    return client.post("/v1/jobs", headers=headers, data={"metadata": json.dumps(metadata or base)},
                       files={"image": ("image.png", image, "image/png"), "mask": ("mask.png", mask, "image/png")})


def test_capabilities_keep_legacy_default_and_gate_experimental_selection(service_factory):
    client, app, headers, _ = service_factory()
    caps = client.get("/v1/capabilities", headers=headers).json()
    assert caps["presets"][0]["id"] == "paint-edit-v1"
    assert caps["cancelSupported"] is False
    assert caps["jobDeletionSupported"] is True
    candidate = next(item for item in caps["presets"] if item["id"] == "test-edit-v1")
    assert candidate["enabled"] is False
    meta, _, _ = example("test-edit-v1")
    rejected = submit(client, headers, meta)
    assert rejected.status_code == 503
    assert rejected.json()["error"]["code"] == "preset_disabled"
    assert app.state.store.pending() == []
    assert submit(client, headers).status_code == 202


def test_explicitly_enabled_preset_is_accepted_and_frozen(service_factory):
    client, app, headers, _ = service_factory(enable_experimental=True)
    meta, _, _ = example("test-edit-v1")
    response = submit(client, headers, meta)
    assert response.status_code == 202, response.text
    stored = app.state.store.get(response.json()["jobId"])
    assert stored["execution_snapshot"]["presetId"] == "test-edit-v1"
    assert stored["execution_snapshot"]["parameters"] == {"prompt": meta["prompt"], "seed": meta["seed"]}
    assert set(stored["execution_snapshot"]["normalizedInputs"]) == {"imageSha256", "maskSha256"}
    assert response.json()["workflowPreset"] == "test-edit-v1"
    assert "graph" not in response.json()["execution"]


def test_identical_retry_works_when_backend_and_preset_are_gone(service_factory):
    client, app, headers, presets = service_factory()
    first = submit(client, headers)
    assert first.status_code == 202
    (presets / "paint-edit-v1.json").unlink()
    unavailable = AsyncMock(side_effect=ComfyError("offline", "comfy_unavailable", True))
    app.state.backend.freeze = unavailable
    replay = submit(client, headers)
    assert replay.status_code == 200
    assert replay.json()["jobId"] == first.json()["jobId"]
    unavailable.assert_not_awaited()
    meta, _, _ = example("paint-edit-v1")
    meta["prompt"] = "changed payload"
    assert submit(client, headers, meta).status_code == 409
    app.state.store.fail(first.json()["jobId"], "test", "finished")
    assert client.delete("/v1/jobs/" + first.json()["jobId"], headers=headers).status_code == 200
    assert submit(client, headers).status_code == 410
    unavailable.assert_not_awaited()


def test_unknown_metadata_stays_rejected_before_dependency_work(service_factory):
    client, app, headers, _ = service_factory()
    app.state.backend.freeze = AsyncMock()
    meta, _, _ = example("paint-edit-v1")
    meta["candidateCount"] = 4
    response = submit(client, headers, meta)
    assert response.status_code == 422
    app.state.backend.freeze.assert_not_awaited()


def test_queue_full_returns_retryable_429_but_replay_still_succeeds(service_factory):
    client, app, headers, _ = service_factory(max_pending_jobs=1)
    first = submit(client, headers)
    assert first.status_code == 202
    meta, _, _ = example("paint-edit-v1")
    meta["clientRequestId"] = "second-request"
    blocked = submit(client, headers, meta)
    assert blocked.status_code == 429
    assert blocked.json()["error"]["code"] == "queue_full"
    assert blocked.headers["Retry-After"] == "5"
    replay = submit(client, headers)
    assert replay.status_code == 200
    assert replay.json()["jobId"] == first.json()["jobId"]
    assert len(app.state.store.pending()) == 1


def test_one_missing_preset_does_not_block_another(service_factory):
    client, app, headers, _ = service_factory(enable_experimental=True)
    original = app.state.backend.freeze

    async def missing(metadata):
        if metadata["workflowPreset"] == "test-edit-v1":
            raise ComfyError("The selected preset is missing a model.", "preset_unavailable")
        return await original(metadata)

    app.state.backend.freeze = missing
    meta, _, _ = example("test-edit-v1")
    response = submit(client, headers, meta)
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "preset_unavailable"
    assert submit(client, headers).status_code == 202
    app.state.backend.preflight = AsyncMock(return_value={"ok": True, "presetId": "test-edit-v1"})
    result = client.get("/v1/backend/status?presetId=test-edit-v1", headers=headers)
    assert result.status_code == 200
    app.state.backend.preflight.assert_awaited_once_with("test-edit-v1")


@pytest.mark.parametrize("held_origin", (None, "http://127.0.0.1:9999"))
def test_status_reports_held_endpoint_mismatch_without_querying_or_exposing_it(service_factory, held_origin):
    client, app, headers, _ = service_factory()
    first = submit(client, headers)
    job_id = first.json()["jobId"]
    app.state.store.set_hold(job_id, "prompt-a", backend_url=held_origin)
    app.state.store.fail(job_id, "job_timeout", "still running")
    app.state.store.delete(job_id)
    app.state.backend.preflight = AsyncMock(side_effect=ComfyError("unavailable", "comfy_unavailable", True))
    response = client.get("/v1/backend/status", headers=headers)
    assert response.status_code == 200
    assert response.json()["ok"] is False
    assert response.json()["executorHeld"] is True
    assert response.json()["error"]["code"] == "executor_connection_mismatch"
    assert app.state.settings.comfy_url not in response.text
    if held_origin:
        assert held_origin not in response.text
    app.state.backend.preflight.assert_not_awaited()
    assert app.state.store.get_hold()["backend_url"] == held_origin


def test_status_accepts_matching_held_endpoint_and_retains_normal_preflight(service_factory, tmp_path):
    client, app, headers, _ = service_factory(comfy_models_dir=tmp_path / "models", comfy_install_dir=tmp_path / "install")
    job_id = submit(client, headers).json()["jobId"]
    app.state.store.set_hold(job_id, "prompt-a", backend_url=app.state.settings.comfy_url + "/")
    app.state.backend.preflight = AsyncMock(return_value={"ok": True, "presetId": "paint-edit-v1"})
    response = client.get("/v1/backend/status", headers=headers)
    assert response.status_code == 200
    assert response.json()["ok"] is True
    assert response.json()["executorHeld"] is True
    app.state.backend.preflight.assert_awaited_once_with("paint-edit-v1")


def test_registry_mutation_cannot_change_an_accepted_job(service_factory):
    client, app, headers, presets = service_factory()
    first = submit(client, headers)
    assert first.status_code == 202
    before = app.state.store.get(first.json()["jobId"])["execution_snapshot"]
    graph_path = presets / "paint-edit-v1.json"
    graph = json.loads(graph_path.read_text("utf-8"))
    graph["15"]["inputs"]["noise_seed"] = 987654
    graph_path.write_text(json.dumps(graph), "utf-8")
    assert submit(client, headers).status_code == 200
    assert app.state.store.get(first.json()["jobId"])["execution_snapshot"] == before
    meta, _, _ = example("paint-edit-v1")
    meta["clientRequestId"] = "new-request"
    rejected = submit(client, headers, meta)
    assert rejected.status_code == 503
    assert rejected.json()["error"]["code"] == "preset_changed"


def test_frozen_prepare_uses_stored_graph_after_catalogue_file_removed(tmp_path):
    source = Path(__file__).parents[1] / "bridge" / "presets"
    presets = tmp_path / "presets"
    shutil.copytree(source, presets)
    meta, image, mask = example("paint-edit-v1")
    snapshot = PresetRegistry(presets).freeze("paint-edit-v1", meta)
    snapshot["runtime"] = {"testDependency": "one"}
    snapshot["dependencyFingerprint"] = digest_json(snapshot["runtime"])
    original = copy.deepcopy(snapshot)
    image_path, mask_path = tmp_path / "image.png", tmp_path / "mask.png"
    image_path.write_bytes(image)
    mask_path.write_bytes(mask)

    async def exercise():
        async with ComfyBackend("http://unused", presets) as backend:
            (presets / "paint-edit-v1.json").unlink()
            backend._runtime_identity = AsyncMock(return_value=snapshot["runtime"])
            backend.preflight = AsyncMock(return_value={"ok": True})
            backend._json = AsyncMock(return_value={"name": "source.png", "subfolder": "ipad_bridge/job-a", "type": "input"})
            graph = await backend.prepare(image_path, mask_path, meta, "job-a", snapshot)
            assert graph["15"]["inputs"]["noise_seed"] == meta["seed"]
            assert graph["7"]["inputs"]["text"] == meta["prompt"]
            assert snapshot == original
            backend._runtime_identity = AsyncMock(return_value={"testDependency": "changed"})
            with pytest.raises(ComfyError) as rejected:
                await backend.prepare(image_path, mask_path, meta, "job-b", snapshot)
            assert rejected.value.code == "dependency_changed"

    asyncio.run(exercise())

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from bridge.store import Store
from test_app import example
from tools.release_executor import release


def test_operator_release_requires_confirmation_idle_backend_and_terminal_task(tmp_path):
    store = Store(tmp_path)
    meta, image, mask = example("paint-edit-v1")
    job, _ = store.create(meta, image, mask, "comfyui")
    store.set_hold(job["id"])
    with pytest.raises(ValueError, match="confirmation"):
        asyncio.run(release(tmp_path, "http://127.0.0.1:8388", False))
    with pytest.raises(ValueError, match="active"):
        asyncio.run(release(tmp_path, "http://127.0.0.1:8388", True))
    store.fail(job["id"], "submission_unknown", "unknown")
    with patch("tools.release_executor.ComfyBackend.queue_idle", new=AsyncMock(return_value=False)):
        with pytest.raises(ValueError, match="still has work"):
            asyncio.run(release(tmp_path, "http://127.0.0.1:8388", True))
    assert store.get_hold()
    store.delete(job["id"])
    with patch("tools.release_executor.ComfyBackend.queue_idle", new=AsyncMock(return_value=True)):
        assert asyncio.run(release(tmp_path, "http://127.0.0.1:8388", True))
    assert store.get_hold() is None
    with store.connect() as db:
        assert db.execute("SELECT state FROM jobs WHERE id=?", (job["id"],)).fetchone()[0] == "deleted"


def test_operator_release_rejects_different_endpoint_before_query(tmp_path):
    store = Store(tmp_path)
    meta, image, mask = example("paint-edit-v1")
    job, _ = store.create(meta, image, mask, "comfyui")
    store.set_hold(job["id"], backend_url="http://127.0.0.1:8388/")
    store.fail(job["id"], "submission_unknown", "unknown")
    store.delete(job["id"])
    with patch("tools.release_executor.ComfyBackend.queue_idle", new=AsyncMock(return_value=True)) as idle:
        with pytest.raises(ValueError, match="endpoint"):
            asyncio.run(release(tmp_path, "http://127.0.0.1:8389", True))
        idle.assert_not_awaited()
        assert store.get_hold()["backend_url"] == "http://127.0.0.1:8388"
        assert asyncio.run(release(tmp_path, "http://127.0.0.1:8388/", True))
    assert store.get_hold() is None

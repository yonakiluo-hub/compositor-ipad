import asyncio
import contextlib
import hashlib
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import AsyncMock

from bridge.comfy import ComfyError
from bridge.config import Settings
from bridge.store import Store, utc_now
from bridge.worker import Worker
from test_app import example


class FakeComfy:
    def __init__(self, generated, unknown=False, recover=True):
        self.generated = generated
        self.unknown = unknown
        self.recover = recover
        self.submits = 0
        self.idle = True
        self.state = "succeeded"
        self.prepared_snapshots = []

    async def queue_idle(self):
        return self.idle

    async def prepare(self, *args):
        self.prepared_snapshots.append(args[-1])
        return {"test": "graph"}

    async def submit(self, *args):
        self.submits += 1
        self.idle = False
        if self.unknown:
            raise ComfyError("unknown", "submit_unknown", True)
        return "prompt-a"

    async def find_job(self, *args):
        return "prompt-a" if self.recover else None

    async def inspect(self, *args):
        if self.state in {"succeeded", "failed"}:
            self.idle = True
        return {"state": self.state, "outputs": [{"filename": "result.png"}],
                "code": "out_of_memory", "error": "The GPU ran out of memory."}

    async def download(self, *args):
        return self.generated


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(Path(self.temp.name), backend="comfyui", poll_seconds=0.001, recovery_seconds=0.02)
        self.store = Store(self.settings.data_dir)
        self.meta, self.image, self.mask = example("paint-edit-v1")
        self.snapshot = {"presetVersion": "1.0.0", "graph": {"frozen": True}, "comfyOrigin": self.settings.comfy_url,
                         "normalizedInputs": {"imageSha256": hashlib.sha256(self.image).hexdigest(),
                                              "maskSha256": hashlib.sha256(self.mask).hexdigest()}}
        self.job, _ = self.store.create(self.meta, self.image, self.mask, "comfyui", execution_snapshot=self.snapshot)

    async def asyncTearDown(self):
        self.temp.cleanup()

    async def test_unknown_submission_recovers_without_duplicate(self):
        backend = FakeComfy(self.image, unknown=True)
        await Worker(self.settings, self.store, backend).process(self.job["id"])
        self.assertEqual(backend.submits, 1)
        self.assertEqual(self.store.get(self.job["id"])["state"], "succeeded")

    async def test_unrecoverable_submission_is_not_retried(self):
        backend = FakeComfy(self.image, unknown=True, recover=False)
        await Worker(self.settings, self.store, backend).process(self.job["id"])
        result = self.store.get(self.job["id"])
        self.assertEqual(backend.submits, 1)
        self.assertEqual(result["error"]["code"], "submission_unknown")

    async def test_completed_job_recovers_after_long_bridge_downtime(self):
        backend = FakeComfy(self.image)
        self.store.update(self.job["id"], state="running", prompt_id="prompt-a", submitting_at="2000-01-01T00:00:00Z")
        with self.store.connect() as db:
            db.execute("UPDATE jobs SET created_at=? WHERE id=?", ("2000-01-01T00:00:00Z", self.job["id"]))
        await Worker(self.settings, self.store, backend).process(self.job["id"])
        self.assertEqual(backend.submits, 0)
        self.assertEqual(self.store.get(self.job["id"])["state"], "succeeded")

    async def test_crash_after_marking_submission_does_not_create_new_prompt(self):
        backend = FakeComfy(self.image, recover=False)
        self.store.update(self.job["id"], state="running", submitting_at="2000-01-01T00:00:00Z")
        await Worker(self.settings, self.store, backend).process(self.job["id"])
        self.assertEqual(backend.submits, 0)
        self.assertEqual(self.store.get(self.job["id"])["error"]["code"], "submission_unknown")

    def next_job(self, request_id="request-next"):
        metadata = {**self.meta, "clientRequestId": request_id}
        return self.store.create(metadata, self.image, self.mask, "comfyui", execution_snapshot=self.snapshot)[0]

    async def test_timeout_hold_survives_restart_deletion_and_blocks_next_submission(self):
        self.settings.job_timeout_seconds = 0.003
        backend = FakeComfy(self.image)
        backend.state = "running"
        await Worker(self.settings, self.store, backend).process(self.job["id"])
        self.assertEqual(self.store.get(self.job["id"])["error"]["code"], "job_timeout")
        self.assertEqual(self.store.get_hold()["job_id"], self.job["id"])
        following = self.next_job()
        self.store.delete(self.job["id"])
        reopened = Store(self.settings.data_dir)
        worker = Worker(self.settings, reopened, backend)
        await worker.process(following["id"])
        self.assertEqual(backend.submits, 1)
        self.assertEqual(reopened.get(following["id"])["state"], "queued")
        self.assertEqual(reopened.get_hold()["job_id"], self.job["id"])
        backend.idle = True
        backend.state = "succeeded"
        await worker.process(following["id"])
        self.assertEqual(backend.submits, 2)
        self.assertEqual(reopened.get(following["id"])["state"], "succeeded")
        self.assertFalse(reopened.job_dir(self.job["id"]).exists())

    async def test_late_completion_cannot_replace_a_timeout_result(self):
        self.settings.job_timeout_seconds = 0.003
        backend = FakeComfy(self.image)
        backend.state = "running"
        worker = Worker(self.settings, self.store, backend)
        await worker.process(self.job["id"])
        terminal = self.store.get(self.job["id"])
        backend.state = "succeeded"
        await worker.process(self.job["id"])
        self.store.succeed(self.job["id"], self.image)
        self.assertEqual(self.store.get(self.job["id"]), terminal)
        self.assertEqual(backend.submits, 1)
        self.assertFalse((self.store.job_dir(self.job["id"]) / "result.png").exists())

    async def test_non_bridge_queue_blocks_submission_without_claiming_job(self):
        backend = FakeComfy(self.image)
        backend.idle = False
        worker = Worker(self.settings, self.store, backend)
        await worker.process(self.job["id"])
        self.assertEqual(self.store.get(self.job["id"])["state"], "queued")
        self.assertEqual(backend.submits, 0)
        backend.idle = True
        await worker.process(self.job["id"])
        self.assertEqual(backend.submits, 1)

    async def test_missing_history_does_not_resubmit_or_release_busy_gpu(self):
        backend = FakeComfy(self.image)
        backend.state = "missing"
        backend.idle = False
        self.store.update(self.job["id"], state="running", prompt_id="prompt-a", submitting_at="2000-01-01T00:00:00Z")
        worker = Worker(self.settings, self.store, backend)
        await worker.process(self.job["id"])
        self.assertEqual(self.store.get(self.job["id"])["error"]["code"], "task_not_found")
        self.assertEqual(backend.submits, 0)
        self.assertIsNotNone(self.store.get_hold())
        following = self.next_job()
        await worker.process(following["id"])
        self.assertEqual(self.store.get(following["id"])["state"], "queued")
        self.assertEqual(backend.submits, 0)

    async def test_oom_is_terminal_without_fallback_and_next_job_waits_for_release(self):
        backend = FakeComfy(self.image)
        backend.state = "failed"
        worker = Worker(self.settings, self.store, backend)
        await worker.process(self.job["id"])
        self.assertEqual(self.store.get(self.job["id"])["error"]["code"], "out_of_memory")
        self.assertEqual(backend.submits, 1)
        self.assertEqual(backend.prepared_snapshots, [self.snapshot])
        following = self.next_job()
        backend.idle = False
        await worker.process(following["id"])
        self.assertEqual(backend.submits, 1)
        backend.idle = True
        backend.state = "succeeded"
        await worker.process(following["id"])
        self.assertEqual(backend.submits, 2)
        self.assertEqual(self.store.get(following["id"])["state"], "succeeded")

    async def test_changed_stored_input_is_rejected_before_upload_or_submission(self):
        backend = FakeComfy(self.image)
        (self.store.job_dir(self.job["id"]) / "input.png").write_bytes(self.image + b"changed")
        await Worker(self.settings, self.store, backend).process(self.job["id"])
        self.assertEqual(self.store.get(self.job["id"])["error"]["code"], "input_changed")
        self.assertEqual(backend.prepared_snapshots, [])
        self.assertEqual(backend.submits, 0)

    async def test_legacy_unsubmitted_job_without_snapshot_is_not_reinterpreted(self):
        backend = FakeComfy(self.image)
        metadata = {**self.meta, "clientRequestId": "legacy-request"}
        legacy, _ = self.store.create(metadata, self.image, self.mask, "comfyui")
        await Worker(self.settings, self.store, backend).process(legacy["id"])
        self.assertEqual(self.store.get(legacy["id"])["error"]["code"], "legacy_snapshot_missing")
        self.assertEqual(backend.submits, 0)

    async def test_backend_disconnect_before_queue_gate_leaves_job_queued(self):
        class OfflineComfy(FakeComfy):
            async def queue_idle(self):
                raise ComfyError("ComfyUI is unavailable.", "comfy_unavailable", True)

        backend = OfflineComfy(self.image)
        task = asyncio.create_task(Worker(self.settings, self.store, backend).run())
        try:
            await asyncio.sleep(0.01)
            self.assertEqual(self.store.get(self.job["id"])["state"], "queued")
            self.assertEqual(backend.submits, 0)
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    async def test_explicit_prompt_rejection_releases_hold_without_retry(self):
        class RejectedComfy(FakeComfy):
            async def submit(self, *args):
                self.submits += 1
                raise ComfyError("The prompt was rejected.", "prompt_rejected")

        backend = RejectedComfy(self.image)
        await Worker(self.settings, self.store, backend).process(self.job["id"])
        self.assertEqual(self.store.get(self.job["id"])["error"]["code"], "prompt_rejected")
        self.assertEqual(backend.submits, 1)
        self.assertIsNone(self.store.get_hold())

    async def test_unknown_submission_hold_survives_empty_queue_until_correlated(self):
        backend = FakeComfy(self.image, unknown=True, recover=False)
        worker = Worker(self.settings, self.store, backend)
        await worker.process(self.job["id"])
        self.assertEqual(self.store.get(self.job["id"])["error"]["code"], "submission_unknown")
        self.assertIsNone(self.store.get_hold()["prompt_id"])
        following = self.next_job()
        # Neither an empty queue, a long elapsed interval nor deletion proves
        # that the unknown /prompt request cannot still be accepted later.
        backend.idle = True
        with self.store.connect() as db:
            db.execute("UPDATE executor_hold SET created_at='2000-01-01T00:00:00Z'")
        self.store.delete(self.job["id"])
        restarted = Worker(self.settings, Store(self.settings.data_dir), backend)
        for _ in range(3):
            await restarted.process(following["id"])
        self.assertEqual(backend.submits, 1)
        self.assertEqual(self.store.get(following["id"])["state"], "queued")
        self.assertEqual(self.store.get_hold()["job_id"], self.job["id"])
        backend.recover = True
        backend.unknown = False
        await restarted.process(following["id"])
        self.assertEqual(backend.submits, 2)
        self.assertEqual(self.store.get(following["id"])["state"], "succeeded")

    async def test_other_endpoint_or_unknown_legacy_endpoint_cannot_release_hold(self):
        backend = FakeComfy(self.image)
        backend.queue_idle = AsyncMock(return_value=True)
        backend.find_job = AsyncMock(return_value="prompt-a")
        backend.inspect = AsyncMock()
        self.store.fail(self.job["id"], "job_timeout", "still running elsewhere")
        for index, origin in enumerate((None, "http://127.0.0.1:9999")):
            with self.subTest(origin=origin):
                self.store.set_hold(self.job["id"], "prompt-a", backend_url=origin)
                following = self.next_job(f"following-{index}")
                restarted = Worker(self.settings, Store(self.settings.data_dir), backend)
                await restarted.reconcile_terminal_hold()
                await restarted.process(following["id"])
                self.assertEqual(self.store.get(following["id"])["state"], "queued")
                self.assertEqual(self.store.get_hold()["backend_url"], origin)
                backend.queue_idle.assert_not_awaited()
                backend.find_job.assert_not_awaited()
                backend.inspect.assert_not_awaited()
                self.assertEqual(backend.submits, 0)
                self.store.release_hold(self.job["id"])

    async def test_unsubmitted_frozen_job_fails_if_retargeted_to_other_endpoint(self):
        backend = FakeComfy(self.image)
        backend.queue_idle = AsyncMock(return_value=True)
        changed = replace(self.settings, comfy_url="http://127.0.0.1:9999")
        await Worker(changed, self.store, backend).process(self.job["id"])
        self.assertEqual(self.store.get(self.job["id"])["error"]["code"], "backend_changed")
        backend.queue_idle.assert_not_awaited()
        self.assertEqual(backend.submits, 0)

    async def test_submitted_frozen_job_does_not_query_another_endpoint(self):
        backend = FakeComfy(self.image)
        backend.queue_idle = AsyncMock(return_value=True)
        backend.find_job = AsyncMock()
        backend.inspect = AsyncMock()
        self.store.update(self.job["id"], state="running", prompt_id="prompt-a", submitting_at=utc_now())
        self.store.set_hold(self.job["id"], "prompt-a", backend_url=self.settings.comfy_url)
        changed = replace(self.settings, comfy_url="http://127.0.0.1:9999")
        await Worker(changed, Store(self.settings.data_dir), backend).process(self.job["id"])
        self.assertEqual(self.store.get(self.job["id"])["state"], "running")
        self.assertEqual(self.store.get_hold()["backend_url"], self.settings.comfy_url)
        backend.queue_idle.assert_not_awaited()
        backend.find_job.assert_not_awaited()
        backend.inspect.assert_not_awaited()
        self.assertEqual(backend.submits, 0)


if __name__ == "__main__":
    unittest.main()

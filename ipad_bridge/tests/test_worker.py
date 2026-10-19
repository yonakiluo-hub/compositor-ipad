import tempfile
import unittest
from pathlib import Path

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

    async def prepare(self, *args):
        return {"test": "graph"}

    async def submit(self, *args):
        self.submits += 1
        if self.unknown:
            raise ComfyError("unknown", "submit_unknown", True)
        return "prompt-a"

    async def find_job(self, *args):
        return "prompt-a" if self.recover else None

    async def inspect(self, *args):
        return {"state": "succeeded", "outputs": [{"filename": "result.png"}]}

    async def download(self, *args):
        return self.generated


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(Path(self.temp.name), backend="comfyui", poll_seconds=0.001, recovery_seconds=0.02)
        self.store = Store(self.settings.data_dir)
        self.meta, self.image, self.mask = example("paint-edit-v1")
        self.job, _ = self.store.create(self.meta, self.image, self.mask, "comfyui")

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


if __name__ == "__main__":
    unittest.main()

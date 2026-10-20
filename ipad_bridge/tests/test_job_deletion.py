import io
import json
import tempfile
import unittest
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from bridge.app import create_app
from bridge.config import Settings
from bridge.store import JobDeleted, Store
from bridge.worker import Worker
from test_app import example


class JobDeletionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(Path(self.temp.name), start_worker=False)
        self.headers = {"Authorization": "Bearer " + self.settings.token()}
        self.app = create_app(self.settings)
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.store = self.app.state.store

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.temp.cleanup()

    def submit(self, metadata=None):
        meta, image, mask = example()
        return self.client.post("/v1/jobs", headers=self.headers,
            data={"metadata": json.dumps(metadata or meta)},
            files={"image": ("image.png", image, "image/png"), "mask": ("mask.png", mask, "image/png")})

    def finished_job(self):
        job_id = self.submit().json()["jobId"]
        self.store.succeed(job_id, example()[1])
        return job_id

    def test_capability_auth_and_only_finished_tasks_can_be_deleted(self):
        self.assertTrue(self.client.get("/v1/capabilities", headers=self.headers).json()["jobDeletionSupported"])
        job_id = self.submit().json()["jobId"]
        url = f"/v1/jobs/{job_id}"
        self.assertEqual(self.client.delete(url).status_code, 401)
        for state in ("queued", "running"):
            with self.subTest(state=state):
                self.store.update(job_id, state=state)
                response = self.client.delete(url, headers=self.headers)
                self.assertEqual(response.status_code, 409)
                self.assertEqual(response.json()["error"]["code"], "job_not_finished")
                self.assertEqual(self.store.get(job_id)["state"], state)
                self.assertTrue((self.store.job_dir(job_id) / "input.png").exists())
        self.store.fail(job_id, "test_failure", "Finished without a candidate")
        self.assertEqual(self.client.delete(url, headers=self.headers).status_code, 200)

    def test_delete_removes_images_and_private_metadata_but_keeps_idempotency(self):
        job_id = self.finished_job()
        folder = self.store.job_dir(job_id)
        (folder / "workflow.json").write_text('{"prompt":"private"}')
        url = f"/v1/jobs/{job_id}"
        for _ in range(2):
            response = self.client.delete(url, headers=self.headers)
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json(), {"jobId": job_id, "deleted": True})
        self.assertFalse(folder.exists())
        for endpoint in (url, url + "/results/0"):
            response = self.client.get(endpoint, headers=self.headers)
            self.assertEqual(response.status_code, 410)
            self.assertEqual(response.json()["error"]["code"], "job_deleted")
        self.assertEqual(self.client.get("/v1/jobs", headers=self.headers).json()["jobs"], [])
        self.assertEqual(self.client.get("/v1/jobs?documentId=document-a", headers=self.headers).json()["jobs"], [])
        for changed in (False, True):
            metadata = example()[0]
            if changed:
                metadata["prompt"] = "Different content still cannot revive a deleted request"
            response = self.submit(metadata)
            self.assertEqual(response.status_code, 410)
            self.assertEqual(response.json()["error"]["code"], "job_deleted")
        self.assertEqual(self.store.pending(), [])
        with self.store.connect() as db:
            rows = db.execute("SELECT * FROM jobs").fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["metadata"], "{}")
        for field in ("prompt_id", "submitting_at", "error", "result_sha256", "result_bytes"):
            self.assertIsNone(rows[0][field])

    def test_delete_preserves_saved_project_and_other_tasks(self):
        job_id = self.finished_job()
        metadata = example()[0]
        metadata["clientRequestId"] = "request-other"
        other_id = self.submit(metadata).json()["jobId"]
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as handle:
            handle.writestr("manifest.json", json.dumps({"format": "com.compositor.project", "version": 14,
                "documentID": "document-a", "layers": []}))
        path = "/v1/documents/document-a/snapshots/7"
        self.assertEqual(self.client.post(path, headers=self.headers,
            files={"archive": ("project.comp.zip", archive.getvalue(), "application/zip")}).status_code, 200)
        self.assertEqual(self.client.delete(f"/v1/jobs/{job_id}", headers=self.headers).status_code, 200)
        self.assertEqual(self.client.get(path, headers=self.headers).content, archive.getvalue())
        self.assertEqual(self.store.get(other_id)["state"], "queued")
        self.assertTrue((self.store.job_dir(other_id) / "input.png").exists())

    def test_cleanup_failure_is_explicit_and_retry_finishes_without_regeneration(self):
        job_id = self.finished_job()
        url = f"/v1/jobs/{job_id}"
        with patch.object(self.store, "_remove_job_files", side_effect=PermissionError()):
            response = self.client.delete(url, headers=self.headers)
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["error"]["code"], "job_deletion_incomplete")
        self.assertTrue(self.store.job_dir(job_id).exists())
        self.assertEqual(self.submit().status_code, 410)
        self.assertEqual(self.client.get(url, headers=self.headers).status_code, 410)
        self.assertEqual(self.client.delete(url, headers=self.headers).status_code, 200)
        self.assertFalse(self.store.job_dir(job_id).exists())

    def test_restart_resumes_partial_cleanup_and_preserves_tombstone(self):
        job_id = self.finished_job()
        folder = self.store.job_dir(job_id)

        def interrupted_cleanup(_):
            (folder / "input.png").unlink()
            raise PermissionError()

        with patch.object(self.store, "_remove_job_files", side_effect=interrupted_cleanup):
            self.assertEqual(self.client.delete(f"/v1/jobs/{job_id}", headers=self.headers).status_code, 503)
        self.assertTrue((folder / "mask.png").exists())
        self.client.__exit__(None, None, None)
        self.app = create_app(self.settings)
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.store = self.app.state.store
        self.assertFalse(folder.exists())
        self.assertEqual(self.submit().status_code, 410)
        self.assertEqual(self.client.delete(f"/v1/jobs/{job_id}", headers=self.headers).status_code, 200)
        self.assertEqual(self.store.pending(), [])

    def test_deletion_cannot_follow_a_symlink_or_arbitrary_path(self):
        job_id = self.finished_job()
        folder = self.store.job_dir(job_id)
        self.store._remove_job_files(job_id)
        protected = Path(self.temp.name) / "protected-project"
        protected.mkdir()
        (protected / "artwork.png").write_bytes(b"personal-artwork")
        for value in ("not-a-uuid", "..%2Fprotected-project", "00000000-0000-0000-0000-000000000000"):
            with self.subTest(value=value):
                self.assertEqual(self.client.delete(f"/v1/jobs/{value}", headers=self.headers).status_code, 404)
        try:
            folder.symlink_to(protected, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("Creating symlinks is unavailable for this platform or user")
        self.assertEqual(self.client.delete(f"/v1/jobs/{job_id}", headers=self.headers).status_code, 200)
        self.assertFalse(folder.is_symlink())
        self.assertEqual((protected / "artwork.png").read_bytes(), b"personal-artwork")
        self.assertTrue(protected.exists())

    def test_parallel_delete_and_late_updates_cannot_revive_task(self):
        job_id = self.finished_job()
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: self.store.delete(job_id), range(8)))
        self.store.update(job_id, state="running", prompt_id="late-response")
        self.store.succeed(job_id, b"late-result")
        self.store.fail(job_id, "late_failure", "late-response")
        self.assertIsNone(self.store.claim(job_id))
        self.assertFalse(self.store.job_dir(job_id).exists())
        with self.assertRaises(JobDeleted):
            self.store.get(job_id)
        meta, image, mask = example()
        with self.assertRaises(JobDeleted):
            self.store.create(meta, image, mask, "mock")


class DeletedWorkerTests(unittest.IsolatedAsyncioTestCase):
    async def test_stale_worker_iteration_does_not_process_deleted_task(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = Settings(Path(directory), start_worker=False)
            store = Store(settings.data_dir)
            meta, image, mask = example()
            job, _ = store.create(meta, image, mask, "mock")
            pending = store.pending()
            store.succeed(job["id"], image)
            store.delete(job["id"])
            for record in pending:
                await Worker(settings, store).process(record["id"])
            self.assertFalse(store.job_dir(job["id"]).exists())
            self.assertEqual(store.pending(), [])

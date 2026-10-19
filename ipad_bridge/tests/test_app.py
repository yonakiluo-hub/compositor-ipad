import copy
import io
import json
import tempfile
import time
import unittest
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from fastapi.testclient import TestClient
from PIL import Image

from bridge.app import MAX_REQUEST_BYTES, create_app
from bridge.config import Settings
from bridge.store import Store


def png(image):
    output = io.BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


def example(preset="mock-paint-v1"):
    metadata = {
        "protocolVersion": 1, "clientRequestId": "request-a", "documentId": "document-a",
        "baseRevision": 7, "sourceLayerIds": ["layer-a"],
        "canvasSize": {"width": 128, "height": 96},
        "cropRect": {"x": 24, "y": 16, "width": 64, "height": 32},
        "inputSize": {"width": 64, "height": 32}, "colorSpace": "sRGB",
        "maskConvention": "white_edit_black_preserve", "workflowPreset": preset,
        "prompt": "Make the painted area blue", "seed": 123,
    }
    image = png(Image.new("RGBA", (64, 32), (180, 130, 60, 255)))
    mask = Image.new("L", (64, 32), 0)
    mask.paste(255, (32, 0, 64, 32))
    return metadata, image, png(mask)


class AppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(Path(self.temp.name), poll_seconds=0.01)
        self.headers = {"Authorization": "Bearer " + self.settings.token()}
        self.app = create_app(self.settings)
        self.client = TestClient(self.app)
        self.client.__enter__()

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.temp.cleanup()

    def submit(self, metadata=None, image=None, mask=None):
        base_meta, base_image, base_mask = example()
        return self.client.post("/v1/jobs", headers=self.headers,
            data={"metadata": json.dumps(metadata or base_meta)},
            files={"image": ("image.png", image or base_image, "image/png"),
                   "mask": ("mask.png", mask or base_mask, "image/png")})

    def finish(self, job_id):
        for _ in range(100):
            response = self.client.get(f"/v1/jobs/{job_id}", headers=self.headers)
            result = response.json()
            if result["state"] in {"succeeded", "failed"}:
                return result
            time.sleep(0.01)
        self.fail("job did not finish")

    def test_auth_before_body_parse_and_size_checks(self):
        response = self.client.post("/v1/jobs", content=b"not multipart")
        self.assertEqual(response.status_code, 401)
        response = self.client.post("/v1/jobs", headers={**self.headers, "Content-Length": str(MAX_REQUEST_BYTES + 1)}, content=b"x")
        self.assertEqual(response.status_code, 413)
        response = self.client.get("/v1/capabilities", headers={"Authorization": "Bearer incorrect"})
        self.assertEqual(response.status_code, 401)

    def test_complete_mock_round_trip_and_protected_download(self):
        response = self.submit()
        self.assertEqual(response.status_code, 202, response.text)
        job = self.finish(response.json()["jobId"])
        self.assertEqual(job["state"], "succeeded", job)
        self.assertTrue(job["isSimulation"])
        self.assertEqual(job["source"]["cropRect"], example()[0]["cropRect"])
        url = job["results"][0]["url"]
        self.assertEqual(self.client.get(url).status_code, 401)
        result = self.client.get(url, headers=self.headers)
        self.assertEqual(result.status_code, 200)
        layer = Image.open(io.BytesIO(result.content)).convert("RGBA")
        self.assertEqual(layer.size, (64, 32))
        self.assertEqual(layer.getchannel("A").crop((0, 0, 32, 32)).getextrema(), (0, 0))
        original = Image.open(io.BytesIO(example()[1])).convert("RGBA")
        composite = Image.alpha_composite(original, layer)
        self.assertEqual(original.crop((0, 0, 32, 32)).tobytes(), composite.crop((0, 0, 32, 32)).tobytes())

    def test_same_request_reuses_job_and_conflict_is_explicit(self):
        first = self.submit()
        second = self.submit()
        self.assertEqual(second.status_code, 200, second.text)
        self.assertEqual(first.json()["jobId"], second.json()["jobId"])
        changed = example()[0]
        changed["prompt"] = "different request"
        self.assertEqual(self.submit(metadata=changed).status_code, 409)

    def test_completed_result_survives_service_restart(self):
        first = self.finish(self.submit().json()["jobId"])
        self.client.__exit__(None, None, None)
        self.app = create_app(self.settings)
        self.client = TestClient(self.app)
        self.client.__enter__()
        again = self.submit()
        self.assertEqual(again.status_code, 200)
        self.assertEqual(again.json()["jobId"], first["jobId"])
        self.assertEqual(again.json()["state"], "succeeded")
        self.assertEqual(self.client.get(first["results"][0]["url"], headers=self.headers).status_code, 200)

    def test_invalid_metadata_mask_and_preset_do_not_queue(self):
        invalid = example()[0]
        invalid["cropRect"]["x"] = 100
        self.assertEqual(self.submit(metadata=invalid).status_code, 422)
        invalid = example()[0]
        invalid["workflowPreset"] = "paint-edit-v1"
        self.assertEqual(self.submit(metadata=invalid).status_code, 422)
        self.assertEqual(self.submit(mask=b"not a png").status_code, 422)
        self.assertEqual(self.client.get("/v1/jobs", headers=self.headers).json()["jobs"], [])

    def test_metadata_size_counts_utf8_bytes(self):
        metadata, image, mask = example()
        metadata["prompt"] = "🎨" * 4000
        metadata["sourceLayerIds"] = ["layer-" + "a" * 120] * 8
        serialized = json.dumps(metadata, ensure_ascii=False)
        self.assertLess(len(serialized), 16384)
        self.assertGreater(len(serialized.encode("utf-8")), 16384)
        response = self.client.post("/v1/jobs", headers=self.headers,
            data={"metadata": serialized},
            files={"image": ("image.png", image, "image/png"),
                   "mask": ("mask.png", mask, "image/png")})
        self.assertEqual(response.status_code, 422)
        self.assertIn("16 KiB", response.json()["error"]["message"])

    def test_document_filter_and_immutable_backup(self):
        self.submit()
        self.assertEqual(len(self.client.get("/v1/jobs?documentId=document-a", headers=self.headers).json()["jobs"]), 1)
        self.assertEqual(self.client.get("/v1/jobs?documentId=other", headers=self.headers).json()["jobs"], [])
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as handle:
            handle.writestr("manifest.json", json.dumps({"format": "com.compositor.project", "version": 14,
                                                     "documentID": "document-a", "layers": []}))
        path = "/v1/documents/document-a/snapshots/7"
        response = self.client.post(path, headers=self.headers, files={"archive": ("project.comp.zip", archive.getvalue(), "application/zip")})
        self.assertEqual(response.status_code, 200, response.text)
        downloaded = self.client.get(path, headers=self.headers)
        self.assertEqual(downloaded.content, archive.getvalue())
        self.assertEqual(len(self.client.get("/v1/documents/document-a/snapshots", headers=self.headers).json()["snapshots"]), 1)

    def test_worker_failure_is_reported_and_stops_new_jobs(self):
        class DeadTask:
            def done(self):
                return True
        self.app.state.worker_task = DeadTask()
        self.assertEqual(self.client.get("/health").status_code, 503)
        self.assertEqual(self.submit().status_code, 503)

    def test_single_process_lock(self):
        with self.assertRaises(RuntimeError):
            with TestClient(create_app(self.settings)):
                pass


class StoreTests(unittest.TestCase):
    def test_concurrent_idempotent_submission(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory))
            meta, image, mask = example()
            with ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda _: store.create(meta, image, mask, "mock"), range(8)))
            self.assertEqual(sum(created for _, created in results), 1)
            self.assertEqual(len({record["id"] for record, _ in results}), 1)

    def test_fingerprint_uses_original_request_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory))
            meta, image, mask = example()
            fingerprint = store.fingerprint(meta, image, mask, "mock")
            first, _ = store.create(meta, image, mask, "mock", fingerprint)
            # A normalization implementation or generated ICC header may vary after restart.
            second, created = store.create(meta, b"new normalization", mask, "mock", fingerprint)
            self.assertFalse(created)
            self.assertEqual(first["id"], second["id"])


if __name__ == "__main__":
    unittest.main()

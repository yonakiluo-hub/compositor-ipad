"""Transport and recovery tests; these never submit work to a real GPU."""
import json
import tempfile
import unittest
from pathlib import Path

import httpx

from bridge.comfy import ComfyBackend, ComfyError


PRESETS = Path(__file__).resolve().parents[1] / "bridge" / "presets"
OUTPUT = {"filename": "candidate_00001_.png", "subfolder": "iPadBridge/job-a", "type": "output"}


def queue_item(prompt_id="prompt-a", job_id="job-a"):
    return [1, prompt_id, {}, {"bridge_job_id": job_id}, ["23"]]


def finished(**overrides):
    result = {
        "prompt": queue_item(),
        "status": {"status_str": "success", "completed": True, "messages": []},
        "outputs": {"23": {"images": [OUTPUT]}},
    }
    result.update(overrides)
    return result


def object_info():
    # Unrelated schemas accept fixed graph fields. Real dropdowns are represented
    # explicitly so unavailable model and unsupported CLIP type checks are tested.
    graph = json.loads((PRESETS / "paint-edit-v1.json").read_text("utf-8"))
    info = {}
    for node in graph.values():
        info[node["class_type"]] = {"input": {"required": {key: ["ANY"] for key in node["inputs"]}}}
    info["UNETLoader"]["input"]["required"]["unet_name"] = [["flux-2-klein-4b-fp8.safetensors"]]
    info["CLIPLoader"]["input"]["required"].update({"clip_name": [["qwen_3_4b.safetensors"]], "type": [["flux2"]]})
    info["VAELoader"]["input"]["required"]["vae_name"] = [["flux2-vae.safetensors"]]
    return info


class ComfyTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.backend = ComfyBackend("http://comfy.test:8188", PRESETS)

    async def asyncTearDown(self):
        await self.backend.close()

    async def mock(self, handler):
        await self.backend.client.aclose()
        self.backend.client = httpx.AsyncClient(base_url="http://comfy.test:8188/", transport=httpx.MockTransport(handler), trust_env=False)

    async def test_prepare_uses_job_input_and_returns_independent_graph(self):
        uploads = []

        def handler(request):
            if request.url.path == "/object_info":
                return httpx.Response(200, json=object_info())
            self.assertEqual(request.url.path, "/upload/image")
            uploads.append(request.content)
            return httpx.Response(200, json={"name": "source.png", "subfolder": "ipad_bridge/job-a", "type": "input"})

        await self.mock(handler)
        with tempfile.TemporaryDirectory() as folder:
            source, mask = Path(folder) / "source.png", Path(folder) / "mask.png"
            source.write_bytes(b"source-image")
            mask.write_bytes(b"private-original-mask")
            metadata = {"workflowPreset": "paint-edit-v1", "prompt": "试画丝绸", "seed": 42}
            graph = await self.backend.prepare(source, mask, metadata, "job-a")
            graph["7"]["inputs"]["text"] = "changed-after-prepare"
            again = await self.backend.prepare(source, mask, metadata, "job-a")
        self.assertEqual(again["1"]["inputs"]["image"], "ipad_bridge/job-a/source.png")
        self.assertEqual(again["7"]["inputs"]["text"], "试画丝绸")
        self.assertEqual(again["15"]["inputs"]["noise_seed"], 42)
        self.assertEqual(again["23"]["inputs"]["filename_prefix"], "iPadBridge/job-a/candidate")
        self.assertNotIn(b"private-original-mask", uploads[0])

    async def test_preflight_reports_models_nodes_and_clip_type_separately(self):
        info = object_info()
        del info["ReferenceLatent"]
        info["UNETLoader"]["input"]["required"]["unet_name"] = [[]]
        info["CLIPLoader"]["input"]["required"]["type"] = [["sdxl"]]
        await self.mock(lambda request: httpx.Response(200, json=info))
        status = await self.backend.preflight("paint-edit-v1")
        self.assertFalse(status["ok"])
        self.assertEqual(status["missingNodes"], ["ReferenceLatent"])
        self.assertEqual(status["missingModels"], ["flux-2-klein-4b-fp8.safetensors"])
        self.assertIn("CLIPLoader.type: unsupported value", status["invalidInputs"])

    async def test_thin_crop_is_rejected_before_upload_or_gpu_submission(self):
        def handler(request):
            self.fail("An invalid crop must not reach the ComfyUI service")
        await self.mock(handler)
        for size in ({"width": 4096, "height": 1}, {"width": 4096, "height": 16}):
            with self.assertRaises(ComfyError) as caught:
                await self.backend.prepare(Path("unused.png"), Path("unused-mask.png"), {
                    "prompt": "edit", "inputSize": size,
                }, "job-a")
            self.assertEqual(caught.exception.code, "invalid_crop")

    async def test_submit_attaches_recovery_key(self):
        def handler(request):
            payload = json.loads(request.content)
            self.assertEqual(payload["extra_data"]["bridge_job_id"], "job-a")
            self.assertEqual(payload["prompt"], {"23": {"class_type": "SaveImage"}})
            return httpx.Response(200, json={"prompt_id": "prompt-a"})
        await self.mock(handler)
        self.assertEqual(await self.backend.submit({"23": {"class_type": "SaveImage"}}, "job-a"), "prompt-a")

    async def test_submit_timeout_does_not_automatically_resubmit(self):
        calls = []
        def handler(request):
            calls.append(request.url.path)
            raise httpx.ReadTimeout("response lost after server accepted request", request=request)
        await self.mock(handler)
        with self.assertRaises(ComfyError) as caught:
            await self.backend.submit({}, "job-a")
        self.assertEqual(caught.exception.code, "submit_unknown")
        self.assertEqual(calls, ["/prompt"])

    async def test_submit_validation_rejection_is_not_ambiguous(self):
        await self.mock(lambda request: httpx.Response(400, json={"error": {"message": "invalid graph", "private_path": "do-not-expose"}}))
        with self.assertRaises(ComfyError) as caught:
            await self.backend.submit({}, "job-a")
        self.assertEqual(caught.exception.code, "prompt_rejected")
        self.assertNotIn("do-not-expose", str(caught.exception))

    async def test_find_job_recovers_history_and_rejects_duplicate_matches(self):
        for duplicate in (False, True):
            def handler(request):
                if request.url.path == "/queue":
                    return httpx.Response(200, json={"queue_running": [queue_item("prompt-b")] if duplicate else [], "queue_pending": []})
                return httpx.Response(200, json={"prompt-a": finished()})
            await self.mock(handler)
            if duplicate:
                with self.assertRaises(ComfyError) as caught:
                    await self.backend.find_job("job-a")
                self.assertEqual(caught.exception.code, "recovery_ambiguous")
            else:
                self.assertEqual(await self.backend.find_job("job-a"), "prompt-a")

    async def test_inspect_handles_completion_between_history_and_queue_reads(self):
        history_reads = []
        def handler(request):
            if request.url.path == "/queue":
                return httpx.Response(200, json={"queue_running": [], "queue_pending": []})
            history_reads.append(request.url.path)
            return httpx.Response(200, json={} if len(history_reads) == 1 else {"prompt-a": finished()})
        await self.mock(handler)
        status = await self.backend.inspect("prompt-a")
        self.assertEqual(status, {"state": "succeeded", "outputs": [OUTPUT]})
        self.assertEqual(len(history_reads), 2)

    async def test_failed_execution_does_not_deliver_partial_output(self):
        await self.mock(lambda request: httpx.Response(200, json={"prompt-a": finished(status={"completed": False, "status_str": "error", "messages": [["execution_error", {"traceback": "private"}]]})}))
        status = await self.backend.inspect("prompt-a")
        self.assertEqual(status["state"], "failed")
        self.assertEqual(status["outputs"], [])
        self.assertNotIn("private", status["error"])

    async def test_inspect_distinguishes_pending_missing_and_no_saved_output(self):
        for state in ("running", "missing", "failed"):
            def handler(request):
                if request.url.path == "/queue":
                    return httpx.Response(200, json={"queue_pending": [queue_item()] if state == "running" else []})
                return httpx.Response(200, json={"prompt-a": finished(outputs={"3": {"images": [{**OUTPUT, "type": "temp"}]}})} if state == "failed" else {})
            await self.mock(handler)
            self.assertEqual((await self.backend.inspect("prompt-a"))["state"], state)

    async def test_download_uses_server_descriptor_and_rejects_traversal(self):
        def handler(request):
            self.assertEqual(request.url.path, "/view")
            self.assertEqual(dict(request.url.params), OUTPUT)
            return httpx.Response(200, content=b"png-content")
        await self.mock(handler)
        self.assertEqual(await self.backend.download(OUTPUT), b"png-content")
        with self.assertRaises(ComfyError):
            await self.backend.download({**OUTPUT, "subfolder": "../outside"})

    async def test_windows_history_subfolder_normalized_for_download(self):
        windows_output = {**OUTPUT, "subfolder": "iPadBridge\\job-a"}
        def handler(request):
            if request.url.path == "/history/prompt-a":
                return httpx.Response(200, json={"prompt-a": finished(outputs={"23": {"images": [windows_output]}})})
            self.assertEqual(request.url.path, "/view")
            self.assertEqual(dict(request.url.params), OUTPUT)
            return httpx.Response(200, content=b"png-content")
        await self.mock(handler)
        status = await self.backend.inspect("prompt-a")
        self.assertEqual(status, {"state": "succeeded", "outputs": [OUTPUT]})
        self.assertEqual(await self.backend.download(status["outputs"][0]), b"png-content")

    async def test_windows_absolute_unc_drive_and_mixed_traversal_rejected(self):
        def handler(request):
            self.fail("Unsafe output directories must not reach the server")
        await self.mock(handler)
        for subfolder in ("\\outside", "\\\\server\\share", "C:\\outside", "C:outside", "a\\..\\outside", "a/..\\outside", "//server/share", "/absolute"):
            with self.subTest(subfolder=subfolder), self.assertRaises(ComfyError):
                await self.backend.download({**OUTPUT, "subfolder": subfolder})


if __name__ == "__main__":
    unittest.main()

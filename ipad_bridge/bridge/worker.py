from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime, timezone

from .config import Settings
from .store import Store, utc_now

log = logging.getLogger(__name__)


def age(timestamp: str) -> float:
    return (datetime.now(timezone.utc) - datetime.fromisoformat(timestamp.replace("Z", "+00:00"))).total_seconds()


class Worker:
    def __init__(self, settings: Settings, store: Store, backend=None):
        self.settings = settings
        self.store = store
        self.backend = backend

    async def run(self):
        while True:
            for record in self.store.pending():
                if record["backend"] != self.settings.backend:
                    # Switching backend must never quietly reinterpret a queued job.
                    continue
                try:
                    await self.process(record["id"])
                except asyncio.CancelledError:
                    raise
                except Exception:
                    log.exception("Job failed: %s", record["id"])
                    self.store.fail(record["id"], "internal_error", "The job could not finish. Check the bridge log.")
            await asyncio.sleep(self.settings.poll_seconds)

    async def process(self, job_id: str):
        from .images import make_result, mock_generate

        record = self.store.get(job_id)
        self.store.update(job_id, state="running")
        folder = self.store.job_dir(job_id)
        mask = (folder / "mask.png").read_bytes()
        if self.settings.backend == "mock":
            generated = await asyncio.to_thread(mock_generate, (folder / "input.png").read_bytes())
            result = await asyncio.to_thread(make_result, generated, mask, record["metadata"])
            self.store.succeed(job_id, result)
            return

        from .comfy import ComfyError

        missing_since = None
        active_start = asyncio.get_running_loop().time()
        while True:
            record = self.store.get(job_id)
            try:
                if not record["prompt_id"]:
                    if record["submitting_at"]:
                        recovered = await self.backend.find_job(job_id)
                        if recovered:
                            self.store.update(job_id, prompt_id=recovered)
                        elif age(record["submitting_at"]) > self.settings.recovery_seconds:
                            self.store.fail(job_id, "submission_unknown", "ComfyUI submission could not be confirmed. No automatic resubmission was made.")
                            return
                        else:
                            await asyncio.sleep(self.settings.poll_seconds)
                        continue
                    graph = await self.backend.prepare(folder / "input.png", folder / "mask.png", record["metadata"], job_id)
                    (folder / "workflow.json").write_text(json.dumps(graph, ensure_ascii=False, indent=2), encoding="utf-8")
                    # This write is intentionally before the network side effect.
                    self.store.update(job_id, submitting_at=utc_now())
                    prompt_id = await self.backend.submit(graph, job_id)
                    self.store.update(job_id, prompt_id=prompt_id)
                    continue
                state = await self.backend.inspect(record["prompt_id"])
                if state["state"] == "succeeded":
                    if not state.get("outputs"):
                        self.store.fail(job_id, "no_image_output", "The workflow finished without a saved image.")
                        return
                    generated = await self.backend.download(state["outputs"][0])
                    result = await asyncio.to_thread(make_result, generated, mask, record["metadata"])
                    self.store.succeed(job_id, result)
                    return
                if state["state"] == "failed":
                    self.store.fail(job_id, "generation_failed", "ComfyUI reported an execution error. See the ComfyUI history for details.")
                    return
                if state["state"] == "missing":
                    missing_since = missing_since or asyncio.get_running_loop().time()
                    if asyncio.get_running_loop().time() - missing_since > self.settings.recovery_seconds:
                        self.store.fail(job_id, "task_not_found", "The submitted task is no longer in ComfyUI queue or history. It was not resubmitted.")
                        return
                else:
                    missing_since = None
            except ComfyError as exc:
                if not exc.retryable:
                    self.store.fail(job_id, exc.code, str(exc)[:500])
                    return
                # Retry reads/uploads; a possibly submitted graph is recovered by ID only.
            if asyncio.get_running_loop().time() - active_start > self.settings.job_timeout_seconds:
                self.store.fail(job_id, "job_timeout", "The bridge stopped waiting. ComfyUI may still be running; no duplicate was submitted.")
                return
            await asyncio.sleep(self.settings.poll_seconds)

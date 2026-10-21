from __future__ import annotations

import asyncio
import json
import logging
import hashlib
from datetime import datetime, timezone

from .config import Settings
from .store import Store, utc_now, JobDeleted

log = logging.getLogger(__name__)


def age(timestamp: str) -> float:
    return (datetime.now(timezone.utc) - datetime.fromisoformat(timestamp.replace("Z", "+00:00"))).total_seconds()


class Worker:
    def __init__(self, settings: Settings, store: Store, backend=None):
        self.settings = settings
        self.store = store
        self.backend = backend

    async def run(self):
        from .comfy import ComfyError
        while True:
            if self.settings.backend == "comfyui":
                try:
                    await self.reconcile_terminal_hold()
                except ComfyError:
                    pass  # Unavailable or ambiguous backend cannot prove the slot is free.
            for record in self.store.pending():
                if record["backend"] != self.settings.backend:
                    # Switching backend must never quietly reinterpret a queued job.
                    continue
                try:
                    await self.process(record["id"])
                except asyncio.CancelledError:
                    raise
                except ComfyError as exc:
                    if not exc.retryable:
                        self.store.fail(record["id"], exc.code, str(exc)[:500])
                except Exception:
                    log.exception("Job failed: %s", record["id"])
                    self.store.fail(record["id"], "internal_error", "The job could not finish. Check the bridge log.")
            await asyncio.sleep(self.settings.poll_seconds)

    async def reconcile_terminal_hold(self):
        hold = self.store.get_hold()
        if not hold:
            return
        if hold.get("backend_url") != self.settings.comfy_url.rstrip("/"):
            return
        try:
            if self.store.get(hold["job_id"])["state"] in {"queued", "running"}:
                return
        except (KeyError, JobDeleted):
            pass
        if not hold.get("prompt_id"):
            prompt_id = await self.backend.find_job(hold["job_id"])
            if not prompt_id:
                return
            self.store.set_hold(hold["job_id"], prompt_id, "late_submission_recovered", backend_url=self.settings.comfy_url.rstrip("/"))
        if await self.backend.queue_idle():
            self.store.release_hold(hold["job_id"])

    async def process(self, job_id: str):
        from .images import make_result, mock_generate

        if self.settings.backend == "comfyui":
            record = self.store.get(job_id)
            hold = self.store.get_hold()
            recovering = record.get("prompt_id") or record.get("submitting_at")
            if record["state"] not in {"queued", "running"}:
                return
            origin = (record.get("execution_snapshot") or {}).get("comfyOrigin")
            if origin and origin != self.settings.comfy_url.rstrip("/"):
                if not recovering:
                    self.store.fail(job_id, "backend_changed", "This queued task belongs to a different ComfyUI connection. It was not submitted to another backend.")
                return
            if hold and hold.get("backend_url") != self.settings.comfy_url.rstrip("/"):
                return  # Never query another endpoint as proof that the old GPU was released.
            # A previous terminal timeout/deletion must not free an executing GPU task.
            if hold and (hold["job_id"] != job_id or not recovering):
                if hold.get("prompt_id") is None:
                    recovered = await self.backend.find_job(hold["job_id"])
                    if not recovered:
                        return  # Empty queue alone cannot rule out an in-flight /prompt request.
                    self.store.set_hold(hold["job_id"], recovered, "late_submission_recovered", backend_url=self.settings.comfy_url.rstrip("/"))
                if not await self.backend.queue_idle():
                    return
                self.store.release_hold(hold["job_id"])
            elif not hold and not recovering and not await self.backend.queue_idle():
                return  # Also covers legacy timeouts and non-bridge work in ComfyUI.
            if recovering:
                self.store.set_hold(job_id, record.get("prompt_id"), "recovering", backend_url=self.settings.comfy_url.rstrip("/"))
        record = self.store.claim(job_id)
        if record is None:
            return
        folder = self.store.job_dir(job_id)
        mask = (folder / "mask.png").read_bytes()
        if self.settings.backend == "mock":
            generated = await asyncio.to_thread(mock_generate, (folder / "input.png").read_bytes())
            result = await asyncio.to_thread(make_result, generated, mask, record["metadata"])
            self.store.succeed(job_id, result)
            return

        from .comfy import ComfyError

        snapshot = record.get("execution_snapshot")
        if snapshot and snapshot.get("executionContractVersion", 1) != 1:
            self.store.fail(job_id, "execution_contract_unsupported", "This task uses an unsupported execution contract. It was not reinterpreted.")
            return
        if not snapshot and not (record["prompt_id"] or record["submitting_at"]):
            self.store.fail(job_id, "legacy_snapshot_missing", "This old queued task has no frozen execution settings. It was not reinterpreted or submitted.")
            return
        if snapshot and snapshot.get("normalizedInputs"):
            inputs = snapshot["normalizedInputs"]
            if (hashlib.sha256((folder / "input.png").read_bytes()).hexdigest() != inputs["imageSha256"]
                    or hashlib.sha256(mask).hexdigest() != inputs["maskSha256"]):
                self.store.fail(job_id, "input_changed", "The stored inputs no longer match the accepted task.")
                return

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
                            self.store.set_hold(job_id, recovered, "recovered", backend_url=self.settings.comfy_url.rstrip("/"))
                        elif age(record["submitting_at"]) > self.settings.recovery_seconds:
                            self.store.fail(job_id, "submission_unknown", "ComfyUI submission could not be confirmed. No automatic resubmission was made.")
                            return
                        else:
                            await asyncio.sleep(self.settings.poll_seconds)
                        continue
                    graph = await self.backend.prepare(folder / "input.png", folder / "mask.png", record["metadata"], job_id, snapshot)
                    (folder / "workflow.json").write_text(json.dumps(graph, ensure_ascii=False, indent=2), encoding="utf-8")
                    # This write is intentionally before the network side effect.
                    self.store.update(job_id, submitting_at=utc_now())
                    self.store.set_hold(job_id, reason="submitting", backend_url=self.settings.comfy_url.rstrip("/"))
                    prompt_id = await self.backend.submit(graph, job_id)
                    self.store.update(job_id, prompt_id=prompt_id)
                    self.store.set_hold(job_id, prompt_id, "submitted", backend_url=self.settings.comfy_url.rstrip("/"))
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
                    self.store.fail(job_id, state.get("code", "generation_failed"), state.get("error", "ComfyUI reported an execution error. See the ComfyUI history for details."))
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
                    if exc.code == "prompt_rejected":
                        self.store.release_hold(job_id)  # HTTP validation rejection proves no execution.
                    return
                # Retry reads/uploads; a possibly submitted graph is recovered by ID only.
            if asyncio.get_running_loop().time() - active_start > self.settings.job_timeout_seconds:
                self.store.fail(job_id, "job_timeout", "The bridge stopped waiting. ComfyUI may still be running; no duplicate was submitted.")
                return
            await asyncio.sleep(self.settings.poll_seconds)

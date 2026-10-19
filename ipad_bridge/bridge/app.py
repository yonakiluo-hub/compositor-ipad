from __future__ import annotations

import asyncio
import contextlib
import json
import os
import secrets
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.exceptions import RequestValidationError

from . import __version__
from .config import Settings
from .store import RequestConflict, Store, public_job
from .worker import Worker

MAX_REQUEST_BYTES = 66 * 1024 * 1024
MAX_IMAGE_BYTES = 20 * 1024 * 1024


class RequestLimits:
    def __init__(self, app, access_token: str):
        self.app = app
        self.authorization = b"Bearer " + access_token.encode("ascii")

    async def __call__(self, scope, receive, send):
        headers = dict(scope.get("headers", []))
        if scope["type"] == "http" and scope["path"].startswith("/v1/"):
            if not secrets.compare_digest(headers.get(b"authorization", b""), self.authorization):
                await JSONResponse({"error": {"code": "unauthorized", "message": "Pair this device with the bridge first."}}, status_code=401,
                                   headers={"WWW-Authenticate": "Bearer"})(scope, receive, send)
                return
        if scope["type"] == "http" and scope["method"] in {"POST", "PUT"}:
            if b"transfer-encoding" in headers or sum(key == b"content-length" for key, _ in scope["headers"]) > 1:
                await JSONResponse({"error": {"code": "invalid_framing", "message": "Use a single Content-Length and no Transfer-Encoding."}}, status_code=400)(scope, receive, send)
                return
            value = headers.get(b"content-length", b"")
            if not value.isdigit():
                await JSONResponse({"error": {"code": "length_required", "message": "Uploads require Content-Length."}}, status_code=411)(scope, receive, send)
                return
            actual_bytes = 0
            original_receive = receive

            async def counted_receive():
                nonlocal actual_bytes
                message = await original_receive()
                if message["type"] == "http.request":
                    actual_bytes += len(message.get("body", b""))
                    if actual_bytes > MAX_REQUEST_BYTES or actual_bytes > int(value):
                        raise HTTPException(413, detail={"code": "request_too_large", "message": "The body exceeds its declared or permitted size."})
                return message

            receive = counted_receive
            if int(value) > MAX_REQUEST_BYTES:
                await JSONResponse({"error": {"code": "request_too_large", "message": "Request exceeds 66 MiB."}}, status_code=413)(scope, receive, send)
                return
        await self.app(scope, receive, send)


class ProcessLock:
    """One worker owns a data directory; OS releases the lock after a crash."""
    def __init__(self, path: Path):
        self.handle = path.open("a+b")

    def acquire(self):
        try:
            self.handle.seek(0)
            if not self.handle.read(1):
                self.handle.write(b"0")
                self.handle.flush()
            self.handle.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.handle.close()
            raise RuntimeError("Another bridge already owns this data directory") from None

    def close(self):
        self.handle.close()


def create_app(settings: Settings) -> FastAPI:
    from .images import normalize_inputs, validate_metadata
    from .snapshots import ConflictError, SnapshotStore

    store = Store(settings.data_dir)
    snapshots = SnapshotStore(settings.data_dir / "snapshots")
    access_token = settings.token()

    @asynccontextmanager
    async def lifespan(app):
        lock = ProcessLock(settings.data_dir / "server.lock")
        lock.acquire()
        backend = None
        task = None
        try:
            if settings.backend == "comfyui":
                from .comfy import ComfyBackend
                backend = ComfyBackend(settings.comfy_url, Path(__file__).parent / "presets")
            app.state.backend = backend
            if settings.start_worker:
                task = asyncio.create_task(Worker(settings, store, backend).run())
            app.state.worker_task = task
            yield
        finally:
            if task:
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await task
            if backend:
                await backend.close()
            lock.close()

    app = FastAPI(title="Compositor Local Bridge", version=__version__, lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(RequestLimits, access_token=access_token)
    app.state.store = store
    app.state.settings = settings

    async def authenticated(authorization: str | None = Header(default=None)):
        if not authorization or not secrets.compare_digest(authorization.encode("utf-8"), b"Bearer " + access_token.encode("ascii")):
            raise HTTPException(401, detail={"code": "unauthorized", "message": "Pair this device with the bridge first."}, headers={"WWW-Authenticate": "Bearer"})

    @app.exception_handler(HTTPException)
    async def http_error(request, exc):
        detail = exc.detail if isinstance(exc.detail, dict) else {"code": "request_error", "message": str(exc.detail)}
        return JSONResponse({"error": detail}, status_code=exc.status_code, headers=exc.headers)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, exc):
        return JSONResponse({"error": {"code": "invalid_request", "message": "Required request fields are missing or invalid.",
                                      "details": [{"field": list(item["loc"]), "message": item["msg"]} for item in exc.errors()]}}, status_code=422)

    def worker_available():
        task = getattr(app.state, "worker_task", None)
        return not settings.start_worker or (task is not None and not task.done())

    def invalid(exc):
        return HTTPException(422, detail={"code": "invalid_input", "message": str(exc)[:500]})

    async def upload_bytes(file: UploadFile, maximum: int):
        content = await file.read(maximum + 1)
        await file.close()
        if len(content) > maximum:
            raise HTTPException(413, detail={"code": "file_too_large", "message": "Uploaded file exceeds the size limit."})
        return content

    def lookup(job_id: str):
        try:
            return store.get(job_id)
        except KeyError:
            raise HTTPException(404, "Job not found") from None

    @app.get("/health")
    async def health():
        return JSONResponse({"status": "ok" if worker_available() else "degraded", "service": "compositor-local-bridge", "version": __version__, "protocolVersion": 1},
                            status_code=200 if worker_available() else 503)

    @app.get("/v1/capabilities", dependencies=[Depends(authenticated)])
    async def capabilities():
        return {
            "protocolVersion": 1, "backend": settings.backend, "isSimulation": settings.backend == "mock",
            "presets": [{"id": settings.preset_id, "technique": "simulation" if settings.backend == "mock" else "reference_edit_with_output_mask",
                         "nativeInpainting": False, "maskAppliedToOutput": True}],
            "maxInputPixels": 4194304, "maxImageBytes": MAX_IMAGE_BYTES,
            "minInputSide": 1 if settings.backend == "mock" else 16,
            "maxInputAspectRatio": None if settings.backend == "mock" else 16,
            "maxSnapshotBytes": 64 * 1024 * 1024, "snapshotFormat": "comp-zip",
            "progressTransport": "polling", "cancelSupported": False,
            "pairingScope": "single-owner-installation", "resultAlphaMode": "straight",
        }

    @app.get("/v1/backend/status", dependencies=[Depends(authenticated)])
    async def backend_status():
        if settings.backend == "mock":
            return {"ok": True, "backend": "mock", "isSimulation": True}
        from .comfy import ComfyError
        try:
            result = await app.state.backend.preflight(settings.preset_id)
            return {**result, "backend": "comfyui", "isSimulation": False}
        except ComfyError as exc:
            return JSONResponse({"ok": False, "backend": "comfyui", "error": {"code": exc.code, "message": str(exc)[:500]}}, status_code=503)

    @app.post("/v1/jobs", dependencies=[Depends(authenticated)])
    async def submit_job(metadata: str = Form(...), image: UploadFile = File(...), mask: UploadFile = File(...)):
        if not worker_available():
            raise HTTPException(503, detail={"code": "worker_unavailable", "message": "Restart the bridge worker before submitting new work."})
        if len(metadata.encode("utf-8")) > 16384:
            raise invalid(ValueError("metadata exceeds 16 KiB"))
        try:
            meta = validate_metadata(json.loads(metadata))
            if meta["workflowPreset"] != settings.preset_id:
                raise ValueError("workflowPreset does not match this server's configured backend")
            if settings.backend == "comfyui":
                width, height = meta["inputSize"].values()
                if not meta["prompt"].strip():
                    raise ValueError("The edit prompt must not be empty")
                if min(width, height) < 16 or max(width, height) > 16 * min(width, height):
                    raise ValueError("Expand the crop context: minimum side is 16 pixels and maximum aspect ratio is 16:1")
            image_data = await upload_bytes(image, MAX_IMAGE_BYTES)
            mask_data = await upload_bytes(mask, MAX_IMAGE_BYTES)
            request_hash = Store.fingerprint(meta, image_data, mask_data, settings.backend)
            image_data, mask_data = await asyncio.to_thread(normalize_inputs, image_data, mask_data, meta)
            record, created = await asyncio.to_thread(store.create, meta, image_data, mask_data, settings.backend, request_hash)
        except RequestConflict as exc:
            raise HTTPException(409, detail={"code": "request_conflict", "message": str(exc)}) from None
        except (ValueError, TypeError) as exc:
            raise invalid(exc) from None
        return JSONResponse(public_job(record), status_code=202 if created else 200)

    @app.get("/v1/jobs", dependencies=[Depends(authenticated)])
    async def list_jobs(documentId: str | None = None, limit: int = Query(default=100, ge=1, le=100)):
        return {"jobs": [public_job(record) for record in store.list(documentId, limit)]}

    @app.get("/v1/jobs/{job_id}", dependencies=[Depends(authenticated)])
    async def get_job(job_id: str):
        return public_job(lookup(job_id))

    @app.get("/v1/jobs/{job_id}/results/{result_id}", dependencies=[Depends(authenticated)])
    async def get_result(job_id: str, result_id: str):
        record = lookup(job_id)
        if result_id != "0" or record["state"] != "succeeded":
            raise HTTPException(404, "Result not available")
        return FileResponse(store.job_dir(job_id) / "result.png", media_type="image/png",
                            headers={"Cache-Control": "private, no-store", "X-Content-SHA256": record["result_sha256"]})

    @app.post("/v1/documents/{document_id}/snapshots/{revision}", dependencies=[Depends(authenticated)])
    async def put_snapshot(document_id: str, revision: int, archive: UploadFile = File(...)):
        payload = await upload_bytes(archive, 64 * 1024 * 1024)
        try:
            metadata = await asyncio.to_thread(snapshots.put, document_id, revision, payload)
        except ConflictError as exc:
            raise HTTPException(409, detail={"code": "snapshot_conflict", "message": str(exc)}) from None
        except ValueError as exc:
            raise invalid(exc) from None
        return metadata

    @app.get("/v1/documents/{document_id}/snapshots", dependencies=[Depends(authenticated)])
    async def list_snapshots(document_id: str):
        try:
            return {"snapshots": await asyncio.to_thread(snapshots.list, document_id)}
        except ValueError as exc:
            raise invalid(exc) from None

    @app.get("/v1/documents/{document_id}/snapshots/{revision}", dependencies=[Depends(authenticated)])
    async def get_snapshot(document_id: str, revision: int):
        try:
            path, metadata = await asyncio.to_thread(snapshots.get, document_id, revision)
        except FileNotFoundError:
            raise HTTPException(404, "Snapshot not found") from None
        except ValueError as exc:
            raise invalid(exc) from None
        return FileResponse(path, media_type="application/zip", filename=f"project-r{revision}.comp.zip",
                            headers={"Cache-Control": "private, no-store", "X-Content-SHA256": metadata["sha256"]})

    @app.get("/v1/openapi.json", dependencies=[Depends(authenticated)])
    async def schema():
        return app.openapi()

    return app

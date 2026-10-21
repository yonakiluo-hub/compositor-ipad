from __future__ import annotations

import hashlib
import json
import logging
import shutil
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class RequestConflict(ValueError):
    pass


class JobDeleted(Exception):
    pass


class JobNotFinished(Exception):
    pass


class QueueFull(Exception):
    pass


class ExecutorBusy(Exception):
    pass


class Store:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.jobs_dir = self.root / "jobs"
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.path = self.root / "jobs.sqlite3"
        self._lock = threading.Lock()
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("""CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, client_request_id TEXT UNIQUE NOT NULL,
                request_hash TEXT NOT NULL, metadata TEXT NOT NULL,
                backend TEXT NOT NULL, state TEXT NOT NULL,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
                prompt_id TEXT, submitting_at TEXT, error TEXT,
                result_sha256 TEXT, result_bytes INTEGER
            )""")
            # Additive migration: an old queued job has no snapshot and must be
            # handled explicitly by the worker, never silently reinterpreted.
            columns = {row["name"] for row in db.execute("PRAGMA table_info(jobs)")}
            for name, kind in (("execution_snapshot", "TEXT"), ("input_bytes", "INTEGER")):
                if name not in columns:
                    db.execute(f"ALTER TABLE jobs ADD COLUMN {name} {kind}")
            # A terminal bridge task may still own an outstanding ComfyUI
            # execution. This small record survives deletion of its artwork.
            db.execute("""CREATE TABLE IF NOT EXISTS executor_hold (
                slot INTEGER PRIMARY KEY CHECK (slot=1), job_id TEXT NOT NULL,
                prompt_id TEXT, created_at TEXT NOT NULL, reason TEXT NOT NULL,
                backend_url TEXT
            )""")
            hold_columns = {row["name"] for row in db.execute("PRAGMA table_info(executor_hold)")}
            if "backend_url" not in hold_columns:
                # Do not guess the endpoint for an execution accepted by old code.
                db.execute("ALTER TABLE executor_hold ADD COLUMN backend_url TEXT")

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    @staticmethod
    def decode(row):
        if row is None:
            return None
        record = dict(row)
        record["metadata"] = json.loads(record["metadata"])
        record["error"] = json.loads(record["error"]) if record["error"] else None
        record["execution_snapshot"] = json.loads(record["execution_snapshot"]) if record.get("execution_snapshot") else None
        return record

    def job_dir(self, job_id: str) -> Path:
        # IDs are server generated; validate again at the filesystem boundary.
        if str(uuid.UUID(job_id)) != job_id:
            raise ValueError("invalid job ID")
        return self.jobs_dir / job_id

    @staticmethod
    def fingerprint(metadata: dict, image: bytes, mask: bytes, backend: str):
        serialized = json.dumps(metadata, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        digest = hashlib.sha256()
        for item in (backend.encode(), serialized.encode(), image, mask):
            digest.update(len(item).to_bytes(8, "big"))
            digest.update(item)
        return digest.hexdigest()

    @staticmethod
    def _check_replay(previous, request_hash):
        if previous:
            if previous["state"] == "deleted":
                raise JobDeleted("This task was deleted. Start a new request to generate again.")
            if previous["request_hash"] != request_hash:
                raise RequestConflict("The request ID already belongs to different content")
        return previous

    def lookup_request(self, client_request_id: str, request_hash: str):
        """Resolve retries before checking dependencies that may have changed."""
        with self.connect() as db:
            previous = self.decode(db.execute("SELECT * FROM jobs WHERE client_request_id=?", (client_request_id,)).fetchone())
        return self._check_replay(previous, request_hash)

    def create(self, metadata: dict, image: bytes, mask: bytes, backend: str, request_hash=None,
               execution_snapshot=None, max_pending=None, max_pending_bytes=None):
        serialized = json.dumps(metadata, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        request_hash = request_hash or self.fingerprint(metadata, image, mask, backend)
        snapshot = json.dumps(execution_snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False) if execution_snapshot is not None else None
        with self._lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = self.decode(db.execute("SELECT * FROM jobs WHERE client_request_id=?", (metadata["clientRequestId"],)).fetchone())
            self._check_replay(previous, request_hash)
            if previous:
                return previous, False
            for limit in (max_pending, max_pending_bytes):
                if limit is not None and (type(limit) is not int or limit < 1):
                    raise ValueError("Queue limits must be positive integers")
            pending = db.execute("SELECT id,input_bytes FROM jobs WHERE state IN ('queued','running')").fetchall()
            if max_pending is not None and len(pending) >= max_pending:
                raise QueueFull("The generation queue is full. Retry this same request later.")
            input_bytes = len(image) + len(mask)
            if max_pending_bytes is not None:
                pending_bytes = 0
                for row in pending:
                    size = row["input_bytes"]
                    if size is None:
                        # Existing databases predate byte accounting. Missing
                        # files are not evidence of free capacity.
                        try:
                            folder = self.job_dir(row["id"])
                            size = sum((folder / name).stat().st_size for name in ("input.png", "mask.png"))
                        except (OSError, ValueError) as exc:
                            raise QueueFull("Pending input storage could not be measured. Retry later.") from exc
                    pending_bytes += size
                if pending_bytes + input_bytes > max_pending_bytes:
                    raise QueueFull("The pending input storage budget is full. Retry this same request later.")
            job_id = str(uuid.uuid4())
            folder = self.job_dir(job_id)
            folder.mkdir()
            # Finish both input files before exposing a queued job to the worker.
            (folder / "input.png").write_bytes(image)
            (folder / "mask.png").write_bytes(mask)
            (folder / "metadata.json").write_text(serialized, encoding="utf-8")
            now = utc_now()
            db.execute("""INSERT INTO jobs
                (id,client_request_id,request_hash,metadata,backend,state,created_at,updated_at,execution_snapshot,input_bytes)
                VALUES (?,?,?,?,?,'queued',?,?,?,?)""",
                (job_id, metadata["clientRequestId"], request_hash, serialized, backend, now, now, snapshot, input_bytes))
            record = self.decode(db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone())
        return record, True

    def get(self, job_id: str):
        with self.connect() as db:
            record = self.decode(db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone())
        if record is None:
            raise KeyError(job_id)
        if record["state"] == "deleted":
            raise JobDeleted("This task and its stored images were deleted.")
        return record

    def claim(self, job_id: str):
        """Check and claim atomically so a stale worker list cannot revive a tombstone."""
        with self._lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            record = self.decode(db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone())
            if record is None or record["state"] not in {"queued", "running"}:
                return None
            db.execute("UPDATE jobs SET state='running',updated_at=? WHERE id=?", (utc_now(), job_id))
            return record

    def delete(self, job_id: str):
        # Commit the tombstone before touching files. A crash or locked file must
        # never turn an old clientRequestId into another inference request.
        with self._lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            record = db.execute("SELECT state FROM jobs WHERE id=?", (job_id,)).fetchone()
            if record is None:
                raise KeyError(job_id)
            if record["state"] not in {"succeeded", "failed", "deleted"}:
                raise JobNotFinished("Only finished tasks can be deleted; this does not cancel generation.")
            # Validate before committing, even if a database was manually edited.
            self.job_dir(job_id)
            if record["state"] != "deleted":
                db.execute("""UPDATE jobs SET state='deleted',metadata='{}',updated_at=?,
                    prompt_id=NULL,submitting_at=NULL,error=NULL,result_sha256=NULL,result_bytes=NULL,
                    execution_snapshot=NULL,input_bytes=NULL
                    WHERE id=?""", (utc_now(), job_id))
        self._remove_job_files(job_id)

    def _remove_job_files(self, job_id: str):
        with self._lock:
            folder = self.job_dir(job_id)
            try:
                # Do not follow a replaced task directory into other artwork or backups.
                if folder.is_symlink():
                    folder.unlink()
                else:
                    shutil.rmtree(folder)
            except FileNotFoundError:
                # An absent child does not prove the remaining directory was removed.
                if folder.exists() or folder.is_symlink():
                    raise

    def cleanup_deleted(self):
        """Resume interrupted file cleanup after the process has acquired its lock."""
        with self.connect() as db:
            ids = [row["id"] for row in db.execute("SELECT id FROM jobs WHERE state='deleted'")]
        for job_id in ids:
            try:
                self._remove_job_files(job_id)
            except (OSError, ValueError):
                logging.getLogger(__name__).warning("Deleted task files need cleanup; retry DELETE for task %s", job_id)

    def pending(self):
        with self.connect() as db:
            return [self.decode(row) for row in db.execute(
                "SELECT * FROM jobs WHERE state IN ('queued','running') ORDER BY created_at").fetchall()]

    def list(self, document_id: str | None = None, limit: int = 100):
        with self.connect() as db:
            if document_id is None:
                rows = db.execute("SELECT * FROM jobs WHERE state!='deleted' ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
            else:
                rows = db.execute("SELECT * FROM jobs WHERE state!='deleted' AND json_extract(metadata,'$.documentId')=? ORDER BY created_at DESC LIMIT ?", (document_id, limit)).fetchall()
        return [self.decode(row) for row in rows]

    def update(self, job_id: str, **fields):
        allowed = {"state", "prompt_id", "submitting_at", "error", "result_sha256", "result_bytes"}
        if not fields or not set(fields) <= allowed:
            raise ValueError("invalid job update")
        if "error" in fields:
            fields["error"] = json.dumps(fields["error"], ensure_ascii=False) if fields["error"] is not None else None
        fields["updated_at"] = utc_now()
        with self._lock, self.connect() as db:
            db.execute(f"UPDATE jobs SET {','.join(key + '=?' for key in fields)} WHERE id=? AND state IN ('queued','running')", (*fields.values(), job_id))

    def set_hold(self, job_id: str, prompt_id: str | None = None, reason: str = "submission_pending", backend_url: str | None = None):
        """Persist ownership before the side effect; never replace another owner."""
        self.job_dir(job_id)
        if backend_url is not None:
            if not isinstance(backend_url, str) or not backend_url.rstrip("/"):
                raise ValueError("A nonempty execution backend URL is required.")
            backend_url = backend_url.rstrip("/")
        with self._lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if not db.execute("SELECT 1 FROM jobs WHERE id=?", (job_id,)).fetchone():
                raise KeyError(job_id)
            previous = db.execute("SELECT * FROM executor_hold WHERE slot=1").fetchone()
            if previous:
                if previous["job_id"] != job_id:
                    raise ExecutorBusy("A previous ComfyUI execution has not been released.")
                if previous["prompt_id"] and prompt_id and previous["prompt_id"] != prompt_id:
                    raise ExecutorBusy("The execution owner already has a different ComfyUI prompt.")
                if previous["backend_url"] is not None and backend_url is not None and previous["backend_url"] != backend_url:
                    raise ExecutorBusy("The held execution belongs to a different ComfyUI endpoint.")
                db.execute("UPDATE executor_hold SET prompt_id=COALESCE(?,prompt_id),reason=?,backend_url=COALESCE(backend_url,?) WHERE slot=1",
                           (prompt_id, reason, backend_url))
            else:
                db.execute("INSERT INTO executor_hold (slot,job_id,prompt_id,created_at,reason,backend_url) VALUES (1,?,?,?,?,?)",
                           (job_id, prompt_id, utc_now(), reason, backend_url))

    def get_hold(self):
        with self.connect() as db:
            row = db.execute("SELECT job_id,prompt_id,created_at,reason,backend_url FROM executor_hold WHERE slot=1").fetchone()
        return dict(row) if row else None

    def release_hold(self, job_id: str):
        with self._lock, self.connect() as db:
            return db.execute("DELETE FROM executor_hold WHERE slot=1 AND job_id=?", (job_id,)).rowcount == 1

    def succeed(self, job_id: str, result: bytes):
        with self._lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            record = db.execute("SELECT state FROM jobs WHERE id=?", (job_id,)).fetchone()
            if record is None or record["state"] not in {"queued", "running"}:
                return
            folder = self.job_dir(job_id)
            partial = folder / "result.png.tmp"
            partial.write_bytes(result)
            partial.replace(folder / "result.png")
            db.execute("""UPDATE jobs SET state='succeeded',error=NULL,result_sha256=?,result_bytes=?,updated_at=?
                WHERE id=?""", (hashlib.sha256(result).hexdigest(), len(result), utc_now(), job_id))

    def fail(self, job_id: str, code: str, message: str):
        self.update(job_id, state="failed", error={"code": code, "message": message})


def public_job(record: dict) -> dict:
    meta = record["metadata"]
    job = {
        "jobId": record["id"], "clientRequestId": meta["clientRequestId"],
        "state": record["state"], "backend": record["backend"],
        "isSimulation": record["backend"] == "mock",
        "createdAt": record["created_at"], "updatedAt": record["updated_at"],
        "source": {key: meta[key] for key in ("documentId", "baseRevision", "sourceLayerIds", "canvasSize", "cropRect", "inputSize", "colorSpace")},
        "workflowPreset": meta["workflowPreset"], "error": record["error"], "results": [],
    }
    snapshot = record.get("execution_snapshot")
    if snapshot:
        # Public provenance contains no graph, prompts, model paths or inputs.
        job["execution"] = {key: snapshot[key] for key in ("presetVersion", "graphHash", "dependencyFingerprint")
                            if isinstance(snapshot.get(key), str)}
    if record["state"] == "succeeded":
        job["results"] = [{
            "resultId": "0", "url": f"/v1/jobs/{record['id']}/results/0",
            "mimeType": "image/png", "width": meta["cropRect"]["width"],
            "height": meta["cropRect"]["height"], "cropRect": meta["cropRect"],
            "colorSpace": "sRGB", "alphaMode": "straight", "maskApplied": True,
            "sha256": record["result_sha256"], "bytes": record["result_bytes"],
        }]
    return job

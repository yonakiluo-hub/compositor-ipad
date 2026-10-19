from __future__ import annotations

import hashlib
import json
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

    def create(self, metadata: dict, image: bytes, mask: bytes, backend: str, request_hash=None):
        serialized = json.dumps(metadata, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        request_hash = request_hash or self.fingerprint(metadata, image, mask, backend)
        with self._lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = self.decode(db.execute("SELECT * FROM jobs WHERE client_request_id=?", (metadata["clientRequestId"],)).fetchone())
            if previous:
                if previous["request_hash"] != request_hash:
                    raise RequestConflict("The request ID already belongs to different content")
                return previous, False
            job_id = str(uuid.uuid4())
            folder = self.job_dir(job_id)
            folder.mkdir()
            # Finish both input files before exposing a queued job to the worker.
            (folder / "input.png").write_bytes(image)
            (folder / "mask.png").write_bytes(mask)
            (folder / "metadata.json").write_text(serialized, encoding="utf-8")
            now = utc_now()
            db.execute("""INSERT INTO jobs
                (id,client_request_id,request_hash,metadata,backend,state,created_at,updated_at)
                VALUES (?,?,?,?,?,'queued',?,?)""",
                (job_id, metadata["clientRequestId"], request_hash, serialized, backend, now, now))
            record = self.decode(db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone())
        return record, True

    def get(self, job_id: str):
        with self.connect() as db:
            record = self.decode(db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone())
        if record is None:
            raise KeyError(job_id)
        return record

    def pending(self):
        with self.connect() as db:
            return [self.decode(row) for row in db.execute(
                "SELECT * FROM jobs WHERE state IN ('queued','running') ORDER BY created_at").fetchall()]

    def list(self, document_id: str | None = None, limit: int = 100):
        with self.connect() as db:
            if document_id is None:
                rows = db.execute("SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
            else:
                rows = db.execute("SELECT * FROM jobs WHERE json_extract(metadata,'$.documentId')=? ORDER BY created_at DESC LIMIT ?", (document_id, limit)).fetchall()
        return [self.decode(row) for row in rows]

    def update(self, job_id: str, **fields):
        allowed = {"state", "prompt_id", "submitting_at", "error", "result_sha256", "result_bytes"}
        if not fields or not set(fields) <= allowed:
            raise ValueError("invalid job update")
        if "error" in fields:
            fields["error"] = json.dumps(fields["error"], ensure_ascii=False) if fields["error"] is not None else None
        fields["updated_at"] = utc_now()
        with self._lock, self.connect() as db:
            db.execute(f"UPDATE jobs SET {','.join(key + '=?' for key in fields)} WHERE id=?", (*fields.values(), job_id))

    def succeed(self, job_id: str, result: bytes):
        folder = self.job_dir(job_id)
        partial = folder / "result.png.tmp"
        partial.write_bytes(result)
        partial.replace(folder / "result.png")
        self.update(job_id, state="succeeded", error=None,
                    result_sha256=hashlib.sha256(result).hexdigest(), result_bytes=len(result))

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
    if record["state"] == "succeeded":
        job["results"] = [{
            "resultId": "0", "url": f"/v1/jobs/{record['id']}/results/0",
            "mimeType": "image/png", "width": meta["cropRect"]["width"],
            "height": meta["cropRect"]["height"], "cropRect": meta["cropRect"],
            "colorSpace": "sRGB", "alphaMode": "straight", "maskApplied": True,
            "sha256": record["result_sha256"], "bytes": record["result_bytes"],
        }]
    return job

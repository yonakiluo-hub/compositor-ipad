"""Immutable, validated Compositor package backups; never extract uploaded ZIPs.

This module deliberately does not decode layer images or rewrite the manifest.
The archive returned to the client is byte-for-byte the archive it uploaded.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import threading
import unicodedata
import uuid
import zipfile
import zlib
from datetime import datetime, timezone
from typing import Any


MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 256 * 1024 * 1024
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_ENTRIES = 2000
MAX_COMPRESSION_RATIO = 1000
MAX_PROJECT_VERSION = 14
_CHUNK_BYTES = 64 * 1024
_ID_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
_DEVICE_PATTERN = re.compile(r"(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?\Z", re.I)
_LOCKS: dict[str, threading.RLock] = {}
_LOCKS_GUARD = threading.Lock()


class SnapshotError(ValueError):
    """The requested backup or archive is invalid."""


class ConflictError(SnapshotError):
    """A document revision already contains a different immutable archive."""


def _document_id(value: str) -> str:
    if not isinstance(value, str) or not _ID_PATTERN.fullmatch(value):
        raise SnapshotError("documentId must contain 1–128 ASCII letters, numbers, underscores or hyphens")
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return value


def _revision(value: int) -> int:
    if type(value) is not int or not 0 <= value <= 2**63 - 1:
        raise SnapshotError("revision must be a nonnegative 64-bit integer")
    return value


def _safe_path(value: str, *, directory: bool = False) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise SnapshotError("archive contains an unsafe path")
    if directory and value.endswith("/"):
        value = value[:-1]
    parts = value.split("/")
    for part in parts:
        if (
            part in ("", ".", "..")
            or any(ord(char) < 32 for char in part)
            or any(char in ':<>"|?*' for char in part)
            or part.endswith((".", " "))
            or _DEVICE_PATTERN.fullmatch(part)
        ):
            raise SnapshotError("archive contains an unsafe path")
    return value


def _path_key(path: str) -> str:
    # Reject aliases that would collide on common macOS or Windows volumes.
    return unicodedata.normalize("NFC", path).casefold()


def _json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SnapshotError("manifest contains duplicate JSON keys")
        result[key] = value
    return result


def _invalid_json_constant(value: str) -> None:
    raise SnapshotError(f"manifest contains invalid JSON constant {value}")


def _validate_manifest(raw: bytes, document_id: str, files: set[str]) -> int:
    try:
        manifest = json.loads(raw, object_pairs_hook=_json_object, parse_constant=_invalid_json_constant)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise SnapshotError("manifest must contain valid JSON") from exc
    if not isinstance(manifest, dict) or manifest.get("format") != "com.compositor.project":
        raise SnapshotError("manifest format must be com.compositor.project")
    version = manifest.get("version")
    if type(version) is not int or not 1 <= version <= MAX_PROJECT_VERSION:
        raise SnapshotError(f"supported project versions are 1–{MAX_PROJECT_VERSION}")
    if _document_id(manifest.get("documentID")) != document_id:
        raise SnapshotError("manifest documentID does not match documentId")
    if not isinstance(manifest.get("layers"), list):
        raise SnapshotError("manifest layers must be an array")
    pending: list[Any] = [manifest]
    while pending:
        item = pending.pop()
        if isinstance(item, dict):
            for key, value in item.items():
                if key in ("imageFile", "maskFile") and value is not None:
                    reference = _safe_path(value)
                    # Compositor stores filenames relative to images/. Also
                    # tolerate explicitly images/-relative paths from clients.
                    asset = reference if reference.startswith("images/") else f"images/{reference}"
                    if asset not in files:
                        raise SnapshotError(f"manifest references a missing asset: {reference}")
                elif isinstance(value, (dict, list)):
                    pending.append(value)
        elif isinstance(item, list):
            pending.extend(item)
    return version


def _validate_archive(archive_bytes: bytes, document_id: str) -> int:
    if not isinstance(archive_bytes, bytes) or not archive_bytes:
        raise SnapshotError("archive must be nonempty bytes")
    if len(archive_bytes) > MAX_ARCHIVE_BYTES:
        raise SnapshotError("archive exceeds the 64 MiB upload limit")
    try:
        with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
            entries = archive.infolist()
            if not entries or len(entries) > MAX_ENTRIES:
                raise SnapshotError(f"archive must contain 1–{MAX_ENTRIES} entries")
            paths: dict[str, zipfile.ZipInfo] = {}
            seen: dict[str, bool] = {}
            declared_total = 0
            for entry in entries:
                path = _safe_path(entry.orig_filename, directory=entry.is_dir())
                key = _path_key(path)
                if key in seen:
                    raise SnapshotError("archive contains duplicate or ambiguous paths")
                seen[key] = entry.is_dir()
                mode = entry.external_attr >> 16
                kind = stat.S_IFMT(mode)
                if kind not in (0, stat.S_IFREG, stat.S_IFDIR) or stat.S_ISLNK(mode):
                    raise SnapshotError("archive contains a link or non-regular entry")
                if kind == stat.S_IFDIR and not entry.is_dir():
                    raise SnapshotError("archive directory metadata is inconsistent")
                if entry.flag_bits & 1:
                    raise SnapshotError("encrypted archives are not supported")
                if entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                    raise SnapshotError("archive must use stored or deflated ZIP entries")
                if entry.is_dir() and entry.file_size:
                    raise SnapshotError("archive directory contains data")
                declared_total += entry.file_size
                if declared_total > MAX_UNCOMPRESSED_BYTES:
                    raise SnapshotError("archive exceeds the 256 MiB uncompressed limit")
                if entry.file_size > 1024 * 1024 and entry.file_size > max(1, entry.compress_size) * MAX_COMPRESSION_RATIO:
                    raise SnapshotError("archive compression ratio is unsafe")
                paths[path] = entry
            for path in paths:
                parts = path.split("/")
                for index in range(1, len(parts)):
                    if seen.get(_path_key("/".join(parts[:index]))) is False:
                        raise SnapshotError("archive uses a file as a directory")

            prefix = ""
            if "manifest.json" not in paths:
                tops = {path.split("/", 1)[0] for path in paths}
                if len(tops) != 1:
                    raise SnapshotError("archive must contain a root manifest.json or one .comp package")
                top = next(iter(tops))
                if not top.endswith(".comp"):
                    raise SnapshotError("archive must contain a root manifest.json or one .comp package")
                prefix = top + "/"
            manifest_name = prefix + "manifest.json"
            manifest_info = paths.get(manifest_name)
            if manifest_info is None or manifest_info.is_dir():
                raise SnapshotError("archive is missing manifest.json")
            if manifest_info.file_size > MAX_MANIFEST_BYTES:
                raise SnapshotError("manifest exceeds the 4 MiB limit")
            raw_manifest = bytearray()
            actual_total = 0
            for path, entry in paths.items():
                if entry.is_dir():
                    continue
                if prefix and not path.startswith(prefix):
                    raise SnapshotError("archive contains files outside its .comp package")
                actual_entry_bytes = 0
                with archive.open(entry) as source:
                    while chunk := source.read(_CHUNK_BYTES):
                        actual_entry_bytes += len(chunk)
                        actual_total += len(chunk)
                        if actual_total > MAX_UNCOMPRESSED_BYTES:
                            raise SnapshotError("archive exceeds the 256 MiB uncompressed limit")
                        if path == manifest_name:
                            if actual_entry_bytes > MAX_MANIFEST_BYTES:
                                raise SnapshotError("manifest exceeds the 4 MiB limit")
                            raw_manifest.extend(chunk)
                if actual_entry_bytes != entry.file_size:
                    raise SnapshotError("archive entry size does not match its metadata")
            files = {path[len(prefix):] for path, entry in paths.items() if not entry.is_dir()}
            return _validate_manifest(bytes(raw_manifest), document_id, files)
    except SnapshotError:
        raise
    except (zipfile.BadZipFile, OSError, EOFError, RuntimeError, NotImplementedError, ValueError, zlib.error) as exc:
        raise SnapshotError("archive is not a valid readable ZIP file") from exc


class SnapshotStore:
    """Store immutable document revisions under hashes, with atomic publication.

    A root-shared lock protects concurrent threads and multiple instances in a
    process. Run one bridge process per data directory (no cross-process lock).
    """

    def __init__(self, root: Path):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        with _LOCKS_GUARD:
            self._lock = _LOCKS.setdefault(os.path.normcase(str(self.root)), threading.RLock())

    def _document_directory(self, document_id: str) -> Path:
        return self.root / hashlib.sha256(document_id.encode("utf-8")).hexdigest()

    def put(self, document_id: str, revision: int, archive_bytes: bytes) -> dict[str, Any]:
        document_id, revision = _document_id(document_id), _revision(revision)
        version = _validate_archive(archive_bytes, document_id)
        digest = hashlib.sha256(archive_bytes).hexdigest()
        with self._lock:
            document_dir = self._document_directory(document_id)
            destination = document_dir / str(revision)
            if destination.exists():
                _, previous = self.get(document_id, revision)
                if previous["sha256"] != digest:
                    raise ConflictError("document revision already contains a different archive")
                return previous
            metadata = {
                "documentId": document_id,
                "revision": revision,
                "sha256": digest,
                "bytes": len(archive_bytes),
                "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "projectVersion": version,
            }
            document_dir.mkdir(parents=True, exist_ok=True)
            # Both files become visible together when the staging directory is
            # renamed. A failed or interrupted write never publishes half a pair.
            with tempfile.TemporaryDirectory(prefix=f".{revision}-", dir=document_dir) as temporary:
                staging = Path(temporary)
                for name, data in (
                    ("archive.zip", archive_bytes),
                    ("metadata.json", json.dumps(metadata, ensure_ascii=False).encode("utf-8")),
                ):
                    with (staging / name).open("xb") as target:
                        target.write(data)
                        target.flush()
                        os.fsync(target.fileno())
                os.replace(staging, destination)
            return metadata

    def list(self, document_id: str) -> list[dict[str, Any]]:
        document_id = _document_id(document_id)
        with self._lock:
            document_dir = self._document_directory(document_id)
            if not document_dir.exists():
                return []
            revisions = sorted(
                int(path.name) for path in document_dir.iterdir()
                if path.is_dir() and path.name.isascii() and path.name.isdecimal()
            )
            return [self.get(document_id, revision)[1] for revision in revisions]

    def get(self, document_id: str, revision: int) -> tuple[Path, dict[str, Any]]:
        document_id, revision = _document_id(document_id), _revision(revision)
        with self._lock:
            destination = self._document_directory(document_id) / str(revision)
            archive = destination / "archive.zip"
            if not archive.is_file():
                raise FileNotFoundError("document revision does not exist")
            metadata = json.loads((destination / "metadata.json").read_text(encoding="utf-8"))
            return archive, metadata

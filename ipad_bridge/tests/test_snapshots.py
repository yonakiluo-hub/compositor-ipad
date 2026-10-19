import concurrent.futures
import hashlib
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from bridge.snapshots import ConflictError, SnapshotError, SnapshotStore


DOCUMENT_ID = "0c5e7a91-3b2d-4f6a-8e1c-9d0b7a6f5e4d"


def package(*, prefix="", manifest_changes=None, extra=(), omit_image=False):
    manifest = {
        "format": "com.compositor.project",
        "version": 14,
        "documentID": DOCUMENT_ID.upper(),
        "layers": [{"imageFile": "layer.png", "maskFile": "layer.mask.png"}],
        "unknownFutureField": {"keep": [1, "verbatim"]},
    }
    manifest.update(manifest_changes or {})
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(prefix + "manifest.json", json.dumps(manifest))
        if not omit_image:
            archive.writestr(prefix + "images/layer.png", b"opaque encoded image bytes")
        archive.writestr(prefix + "images/layer.mask.png", b"opaque encoded mask bytes")
        archive.writestr(prefix + "QuickLook/Preview.jpg", b"opaque preview")
        for name, data in extra:
            archive.writestr(name, data)
    return output.getvalue()


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.store = SnapshotStore(self.root)

    def test_roundtrip_preserves_archive_and_metadata(self):
        uploaded = package()
        created = self.store.put(DOCUMENT_ID, 7, uploaded)
        stored, metadata = self.store.get(DOCUMENT_ID.upper(), 7)
        self.assertEqual(stored.read_bytes(), uploaded)
        self.assertEqual(metadata, created)
        self.assertEqual(created["sha256"], hashlib.sha256(uploaded).hexdigest())
        self.assertEqual(created["bytes"], len(uploaded))
        self.assertEqual(created["projectVersion"], 14)
        self.assertTrue(created["createdAt"].endswith("Z"))
        self.assertEqual(self.store.list(DOCUMENT_ID), [created])
        # No layer image is extracted into the store.
        self.assertEqual(sorted(path.name for path in self.root.rglob("*") if path.is_file()), ["archive.zip", "metadata.json"])

    def test_accepts_comp_prefix_and_quicklook(self):
        uploaded = package(prefix="My Drawing.comp/")
        self.store.put(DOCUMENT_ID, 0, uploaded)
        self.assertEqual(self.store.get(DOCUMENT_ID, 0)[0].read_bytes(), uploaded)

    def test_same_bytes_are_idempotent_and_changed_revision_conflicts(self):
        uploaded = package()
        original = self.store.put(DOCUMENT_ID, 2, uploaded)
        self.assertEqual(self.store.put(DOCUMENT_ID, 2, uploaded), original)
        with self.assertRaises(ConflictError):
            self.store.put(DOCUMENT_ID, 2, package(manifest_changes={"width": 22}))
        self.assertEqual(self.store.get(DOCUMENT_ID, 2)[0].read_bytes(), uploaded)

    def test_missing_revision_and_empty_list(self):
        self.assertEqual(self.store.list(DOCUMENT_ID), [])
        with self.assertRaises(FileNotFoundError):
            self.store.get(DOCUMENT_ID, 0)

    def test_rejects_path_traversal_and_windows_aliases(self):
        for path in ("../outside", "/absolute", "C:/drive", "images/../../escape", "images/file:stream", "images/NUL", "images/trailing."):
            with self.subTest(path=path), self.assertRaises(SnapshotError):
                self.store.put(DOCUMENT_ID, 0, package(extra=[(path, b"bad")]))
        # ZipFile's writer normalizes backslashes on Windows; construct a raw
        # backslash name in both ZIP headers after writing instead.
        uploaded = package(extra=[("images/escape", b"bad")]).replace(b"images/escape", b"images\\escape")
        with self.assertRaises(SnapshotError):
            self.store.put(DOCUMENT_ID, 0, uploaded)

    def test_rejects_duplicate_path_and_case_alias(self):
        for path in ("images/layer.png", "IMAGES/Layer.png"):
            with self.subTest(path=path), self.assertRaises(SnapshotError):
                self.store.put(DOCUMENT_ID, 0, package(extra=[(path, b"duplicate")]))

    def test_rejects_symlink(self):
        link = zipfile.ZipInfo("images/link.png")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with self.assertRaises(SnapshotError):
            self.store.put(DOCUMENT_ID, 0, package(extra=[(link, b"../../outside")]))

    def test_rejects_mismatched_document_and_missing_assets(self):
        for uploaded in (
            package(manifest_changes={"documentID": "different-document"}),
            package(omit_image=True),
            package(manifest_changes={"layers": [{"maskFile": "missing.png"}]}),
            package(manifest_changes={"layers": [{"imageFile": "../manifest.json"}]}),
        ):
            with self.subTest(), self.assertRaises(SnapshotError):
                self.store.put(DOCUMENT_ID, 0, uploaded)

    def test_rejects_wrong_format_or_unsupported_version(self):
        for change in ({"version": 15}, {"version": True}, {"version": 0}, {"format": "other"}, {"layers": None}):
            with self.subTest(change=change), self.assertRaises(SnapshotError):
                self.store.put(DOCUMENT_ID, 0, package(manifest_changes=change))

    def test_rejects_oversized_archive_manifest_entry_count_and_expansion(self):
        for constant, limit in (
            ("MAX_ARCHIVE_BYTES", 1), ("MAX_MANIFEST_BYTES", 1),
            ("MAX_ENTRIES", 1), ("MAX_UNCOMPRESSED_BYTES", 1),
        ):
            with self.subTest(constant=constant), patch(f"bridge.snapshots.{constant}", limit), self.assertRaises(SnapshotError):
                self.store.put(DOCUMENT_ID, 0, package())
        with self.assertRaises(SnapshotError):
            self.store.put(DOCUMENT_ID, 0, package(extra=[("images/bomb", b"0" * (2 * 1024 * 1024))]))

    def test_rejects_encrypted_flag(self):
        uploaded = bytearray(package())
        start = 0
        while (start := uploaded.find(b"PK\x01\x02", start)) != -1:
            uploaded[start + 8] |= 1
            start += 4
        with self.assertRaises(SnapshotError):
            self.store.put(DOCUMENT_ID, 0, bytes(uploaded))

    def test_validates_actual_entry_crc(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
            with zipfile.ZipFile(io.BytesIO(package())) as source:
                for entry in source.infolist():
                    archive.writestr(entry.filename, source.read(entry))
        uploaded = output.getvalue().replace(b"opaque encoded image bytes", b"BROKEN encoded image bytes")
        with self.assertRaises(SnapshotError):
            self.store.put(DOCUMENT_ID, 0, uploaded)

    def test_shared_root_threads_publish_one_immutable_revision(self):
        uploaded = package()
        other = SnapshotStore(self.root)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(lambda index: (self.store if index % 2 else other).put(DOCUMENT_ID, 3, uploaded), range(20)))
        self.assertTrue(all(item == results[0] for item in results))
        self.assertEqual(len(self.store.list(DOCUMENT_ID)), 1)

    def test_invalid_identifiers_and_revisions(self):
        for document_id in ("", "../escape", "x" * 129, "contains space"):
            with self.subTest(document_id=document_id), self.assertRaises(SnapshotError):
                self.store.list(document_id)
        for revision in (-1, True, 1.2, 2**64):
            with self.subTest(revision=revision), self.assertRaises(SnapshotError):
                self.store.get(DOCUMENT_ID, revision)


if __name__ == "__main__":
    unittest.main()

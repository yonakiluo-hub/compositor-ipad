import hashlib
import os
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from bridge.identity import DependencyIdentity, IdentityError, digest_json


@pytest.fixture
def dependencies(tmp_path):
    models = tmp_path / "models"
    (models / "diffusion_models").mkdir(parents=True)
    weight = models / "diffusion_models" / "example.safetensors"
    weight.write_bytes(b"original-weight")
    install = tmp_path / "comfy"
    (install / "comfy_extras").mkdir(parents=True)
    (install / "main.py").write_text("VERSION = 'one'\n")
    (install / "comfy_extras" / "nodes_example.py").write_text("NODE_VERSION = 1\n")
    manifest = [{"category": "diffusion_models", "filename": weight.name, "sha256": None}]
    return DependencyIdentity(models, install), manifest, weight, install


def test_capture_is_repeatable_and_contains_no_absolute_paths(dependencies):
    identity, manifest, weight, _ = dependencies
    first = identity.capture(manifest)
    assert first == identity.capture(manifest)
    assert first["weights"] == [{"category": "diffusion_models", "filename": weight.name,
                                  "sha256": hashlib.sha256(weight.read_bytes()).hexdigest(), "bytes": weight.stat().st_size}]
    assert first["sourceFileCount"] == 2
    assert str(weight.parent) not in str(first)


def test_same_sized_weight_change_invalidates_cached_identity(dependencies):
    identity, manifest, weight, _ = dependencies
    before = identity.capture(manifest)
    old_time = weight.stat().st_mtime_ns
    weight.write_bytes(b"modified-weight")
    os.utime(weight, ns=(old_time + 1_000_000_000, old_time + 1_000_000_000))
    after = identity.capture(manifest)
    assert before["weights"][0]["bytes"] == after["weights"][0]["bytes"]
    assert digest_json(before) != digest_json(after)


def test_node_source_edit_and_addition_change_fingerprint(dependencies):
    identity, manifest, _, install = dependencies
    before = identity.capture(manifest)
    node = install / "comfy_extras" / "nodes_example.py"
    old_time = node.stat().st_mtime_ns
    node.write_text("NODE_VERSION = 2\n")
    os.utime(node, ns=(old_time + 1_000_000_000, old_time + 1_000_000_000))
    edited = identity.capture(manifest)
    assert edited["sourceSha256"] != before["sourceSha256"]
    (install / "comfy_extras" / "nodes_added.py").write_text("NODE_VERSION = 1\n")
    added = identity.capture(manifest)
    assert added["sourceSha256"] != edited["sourceSha256"]
    assert added["sourceFileCount"] == 3


def test_pinned_hash_mismatch_and_missing_weights_fail_closed(dependencies):
    identity, manifest, weight, _ = dependencies
    manifest[0]["sha256"] = "0" * 64
    with pytest.raises(IdentityError, match="pinned digest"):
        identity.capture(manifest)
    manifest[0]["sha256"] = None
    weight.unlink()
    with pytest.raises(IdentityError, match="missing or unreadable"):
        identity.capture(manifest)


def test_missing_configuration_and_install_are_explicit(tmp_path):
    with pytest.raises(IdentityError, match="Configure"):
        DependencyIdentity(None, None).capture([])
    with pytest.raises(IdentityError, match="unavailable"):
        DependencyIdentity(tmp_path, tmp_path).capture([])


def test_weight_traversal_cannot_read_outside_configured_root(dependencies, tmp_path):
    identity, manifest, _, _ = dependencies
    outside = tmp_path / "outside.safetensors"
    outside.write_bytes(b"private")
    manifest[0]["filename"] = "../../outside.safetensors"
    with pytest.raises(IdentityError, match="inside"):
        identity.capture(manifest)


@pytest.mark.parametrize("target", ("weight", "node"))
def test_symlink_dependency_escape_fails_closed(dependencies, tmp_path, target):
    identity, manifest, weight, install = dependencies
    outside = tmp_path / "outside-file"
    outside.write_bytes(b"private")
    link = weight if target == "weight" else install / "comfy_extras" / "nodes_example.py"
    link.unlink()
    try:
        link.symlink_to(outside)
    except (OSError, NotImplementedError):
        pytest.skip("Creating symlinks is unavailable for this platform or user")
    with pytest.raises(IdentityError, match="inside"):
        identity.capture(manifest)


def test_dependency_changed_during_hash_is_rejected(dependencies, monkeypatch):
    identity, manifest, weight, _ = dependencies
    real_digest = hashlib.file_digest

    def changed_after_read(stream, algorithm):
        result = real_digest(stream, algorithm)
        if Path(stream.name) == weight:
            with weight.open("ab") as writer:
                writer.write(b"changed")
        return result

    monkeypatch.setattr(hashlib, "file_digest", changed_after_read)
    with pytest.raises(IdentityError, match="changed while"):
        identity.capture(manifest)


@pytest.mark.parametrize("target", ("weight", "source"))
def test_dependency_newer_than_comfy_process_start_requires_restart(dependencies, target):
    identity, manifest, weight, install = dependencies
    process_started = time.time() + 1
    assert identity.capture(manifest, not_newer_than=process_started)
    path = weight if target == "weight" else install / "comfy_extras" / "nodes_example.py"
    # Both already-cached and new hashes must enforce the process-start boundary.
    os.utime(path, (process_started + 10, process_started + 10))
    with pytest.raises(IdentityError, match="after.*start") as caught:
        identity.capture(manifest, not_newer_than=process_started)
    assert str(path) not in str(caught.value)


@pytest.mark.parametrize("category,alias", (("diffusion_models", "unet"), ("text_encoders", "clip")))
def test_legacy_alias_with_same_filename_is_not_silently_fingerprinted(dependencies, category, alias):
    identity, manifest, weight, _ = dependencies
    category_dir = identity.models_dir / category
    category_dir.mkdir(exist_ok=True)
    (category_dir / weight.name).write_bytes(b"current-model")
    alias_dir = identity.models_dir / alias
    alias_dir.mkdir()
    (alias_dir / weight.name).write_bytes(b"other-model-loaded-by-comfy")
    manifest[0]["category"] = category
    with pytest.raises(IdentityError, match="ambiguity"):
        identity.capture(manifest)


def test_change_between_timestamp_check_and_hash_is_rejected(dependencies, monkeypatch):
    identity, manifest, weight, _ = dependencies
    process_started = time.time() + 1
    real_hash = identity._hash

    def change_before_hash(path, not_newer_than=None):
        if path == weight:
            path.write_bytes(b"replaced-after-precheck")
            os.utime(path, (process_started + 10, process_started + 10))
        return real_hash(path, not_newer_than)

    monkeypatch.setattr(identity, "_hash", change_before_hash)
    with pytest.raises(IdentityError, match="after.*start"):
        identity.capture(manifest, not_newer_than=process_started)


@pytest.mark.parametrize("target", ("weight", "source"))
def test_new_creation_time_is_rejected_even_when_mtime_is_old(dependencies, monkeypatch, target):
    identity, manifest, weight, install = dependencies
    process_started = time.time() + 1
    identity.capture(manifest, not_newer_than=process_started)
    changed_path = weight if target == "weight" else install / "comfy_extras" / "nodes_example.py"
    real_stat = Path.stat

    def changed_creation_time(path, *args, **kwargs):
        stat = real_stat(path, *args, **kwargs)
        if path != changed_path:
            return stat
        values = {name: getattr(stat, name) for name in dir(stat) if name.startswith("st_")}
        values.update(st_ctime=process_started + 10, st_ctime_ns=int((process_started + 10) * 1_000_000_000))
        return SimpleNamespace(**values)

    monkeypatch.setattr(Path, "stat", changed_creation_time)
    with pytest.raises(IdentityError, match="after.*start"):
        identity.capture(manifest, not_newer_than=process_started)

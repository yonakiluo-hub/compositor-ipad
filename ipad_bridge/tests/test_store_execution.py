import copy
import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor

import pytest

from bridge.store import ExecutorBusy, JobDeleted, QueueFull, RequestConflict, Store, public_job
from test_app import example


def create(store, request_id="request-a", **kwargs):
    meta, image, mask = example()
    meta["clientRequestId"] = request_id
    return store.create(meta, image, mask, "mock", **kwargs)


def test_snapshot_is_frozen_in_database_and_replays_do_not_replace_it(tmp_path):
    store = Store(tmp_path)
    snapshot = {"presetVersion": "1.0.0", "graphHash": "a" * 64,
                "dependencyFingerprint": "b" * 64, "graph": {"1": {"inputs": {"seed": 123}}}}
    expected = copy.deepcopy(snapshot)
    job, made = create(store, execution_snapshot=snapshot)
    snapshot["graph"]["1"]["inputs"]["seed"] = 456
    assert made
    assert Store(tmp_path).get(job["id"])["execution_snapshot"] == expected
    replay, made = create(store, execution_snapshot={"presetVersion": "2.0.0"})
    assert not made
    assert replay["execution_snapshot"] == expected
    assert public_job(replay)["execution"] == {key: expected[key] for key in
                                               ("presetVersion", "graphHash", "dependencyFingerprint")}


def test_lookup_preserves_original_byte_fingerprint_and_deleted_precedence(tmp_path):
    store = Store(tmp_path)
    meta, image, mask = example()
    raw_hash = Store.fingerprint(meta, image + b"original-encoding", mask, "mock")
    job, _ = store.create(meta, image, mask, "mock", request_hash=raw_hash)
    assert store.lookup_request(meta["clientRequestId"], raw_hash)["id"] == job["id"]
    assert store.lookup_request("never-seen", raw_hash) is None
    with pytest.raises(RequestConflict):
        store.lookup_request(meta["clientRequestId"], "different")
    store.fail(job["id"], "test", "finished")
    store.delete(job["id"])
    with pytest.raises(JobDeleted):
        store.lookup_request(meta["clientRequestId"], "different")


def test_replay_wins_over_full_queue_and_changed_snapshot(tmp_path):
    store = Store(tmp_path)
    job, _ = create(store, max_pending=1)
    replay, made = create(store, max_pending=1, max_pending_bytes=1, execution_snapshot={"changed": True})
    assert not made
    assert replay["id"] == job["id"]
    with pytest.raises(QueueFull):
        create(store, "request-b", max_pending=1)
    assert len(list(store.jobs_dir.iterdir())) == 1


def test_queue_budget_includes_running_and_releases_only_terminal_capacity(tmp_path):
    store = Store(tmp_path)
    _, image, mask = example()
    size = len(image) + len(mask)
    job, _ = create(store, max_pending_bytes=size)
    store.claim(job["id"])
    with pytest.raises(QueueFull):
        create(store, "request-b", max_pending_bytes=size)
    store.fail(job["id"], "test", "finished")
    _, made = create(store, "request-b", max_pending_bytes=size)
    assert made
    assert len(store.pending()) == 1
    with pytest.raises(QueueFull):
        create(Store(tmp_path / "empty"), max_pending_bytes=size - 1)


def test_queue_limit_is_atomic_across_store_instances(tmp_path):
    stores = [Store(tmp_path), Store(tmp_path)]

    def submit(index):
        try:
            create(stores[index], f"request-{index}", max_pending=1)
            return True
        except QueueFull:
            return False

    with ThreadPoolExecutor(max_workers=2) as pool:
        accepted = list(pool.map(submit, (0, 1)))
    assert sorted(accepted) == [False, True]
    assert len(stores[0].pending()) == 1
    assert len(list(stores[0].jobs_dir.iterdir())) == 1


def test_migration_retains_legacy_jobs_without_inventing_snapshot(tmp_path):
    db = sqlite3.connect(tmp_path / "jobs.sqlite3")
    db.execute("""CREATE TABLE jobs (
        id TEXT PRIMARY KEY, client_request_id TEXT UNIQUE NOT NULL,
        request_hash TEXT NOT NULL, metadata TEXT NOT NULL,
        backend TEXT NOT NULL, state TEXT NOT NULL,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        prompt_id TEXT, submitting_at TEXT, error TEXT,
        result_sha256 TEXT, result_bytes INTEGER
    )""")
    meta, image, mask = example()
    job_id = "00000000-0000-0000-0000-000000000001"
    request_hash = Store.fingerprint(meta, image, mask, "mock")
    db.execute("INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", (
        job_id, meta["clientRequestId"], request_hash, json.dumps(meta), "mock", "queued",
        "2000-01-01T00:00:00Z", "2000-01-01T00:00:00Z", None, None, None, None, None))
    db.commit()
    db.close()
    folder = tmp_path / "jobs" / job_id
    folder.mkdir(parents=True)
    (folder / "input.png").write_bytes(image)
    (folder / "mask.png").write_bytes(mask)
    store = Store(tmp_path)
    legacy = store.get(job_id)
    assert legacy["execution_snapshot"] is None
    assert legacy["input_bytes"] is None
    assert store.lookup_request(meta["clientRequestId"], request_hash)["id"] == job_id
    with pytest.raises(QueueFull):
        create(store, "request-b", max_pending_bytes=len(image) + len(mask))
    (folder / "input.png").unlink()
    with pytest.raises(QueueFull, match="could not be measured"):
        create(store, "request-b", max_pending_bytes=10**6)


def test_hold_persists_through_terminal_delete_and_restart(tmp_path):
    store = Store(tmp_path)
    job, _ = create(store, execution_snapshot={"graph": {"prompt": "private"}})
    store.set_hold(job["id"], backend_url="http://127.0.0.1:8388/")
    original_time = store.get_hold()["created_at"]
    store.set_hold(job["id"], "prompt-a", "running")
    store.fail(job["id"], "job_timeout", "still running")
    store.delete(job["id"])
    restarted = Store(tmp_path)
    assert restarted.get_hold() == {"job_id": job["id"], "prompt_id": "prompt-a",
                                    "created_at": original_time, "reason": "running",
                                    "backend_url": "http://127.0.0.1:8388"}
    with restarted.connect() as db:
        row = db.execute("SELECT * FROM jobs WHERE id=?", (job["id"],)).fetchone()
    assert row["execution_snapshot"] is None
    assert row["metadata"] == "{}"
    assert not restarted.job_dir(job["id"]).exists()
    assert not restarted.release_hold("wrong-owner")
    assert restarted.release_hold(job["id"])
    assert Store(tmp_path).get_hold() is None


def test_hold_cannot_be_stolen_or_rebound(tmp_path):
    store = Store(tmp_path)
    first, _ = create(store)
    second, _ = create(store, "request-b")
    store.set_hold(first["id"], "prompt-a")
    with pytest.raises(ExecutorBusy):
        store.set_hold(second["id"], "prompt-b")
    with pytest.raises(ExecutorBusy):
        store.set_hold(first["id"], "prompt-b")
    store.set_hold(first["id"], reason="unknown")
    assert store.get_hold()["prompt_id"] == "prompt-a"


def test_hold_endpoint_is_retained_and_cannot_be_overwritten(tmp_path):
    store = Store(tmp_path)
    job, _ = create(store)
    store.set_hold(job["id"], backend_url="http://127.0.0.1:8388/")
    store.set_hold(job["id"], "prompt-a", "submitted")
    expected = store.get_hold()
    assert expected["backend_url"] == "http://127.0.0.1:8388"
    with pytest.raises(ExecutorBusy, match="endpoint"):
        Store(tmp_path).set_hold(job["id"], "prompt-a", "recovering", backend_url="http://127.0.0.1:8389")
    assert store.get_hold() == expected
    store.set_hold(job["id"], "prompt-a", "same-endpoint", backend_url="http://127.0.0.1:8388/")
    assert store.get_hold()["backend_url"] == expected["backend_url"]


def test_hold_migration_does_not_invent_legacy_endpoint(tmp_path):
    store = Store(tmp_path)
    job, _ = create(store)
    with store.connect() as db:
        db.execute("DROP TABLE executor_hold")
        db.execute("""CREATE TABLE executor_hold (
            slot INTEGER PRIMARY KEY CHECK (slot=1), job_id TEXT NOT NULL,
            prompt_id TEXT, created_at TEXT NOT NULL, reason TEXT NOT NULL
        )""")
        db.execute("INSERT INTO executor_hold VALUES (1,?,?,?,?)",
                   (job["id"], "legacy-prompt", "2000-01-01T00:00:00Z", "legacy"))
    migrated = Store(tmp_path).get_hold()
    assert migrated["backend_url"] is None
    assert migrated["job_id"] == job["id"]
    assert migrated["prompt_id"] == "legacy-prompt"


@pytest.mark.parametrize("terminal", ("succeeded", "failed"))
def test_terminal_winner_cannot_be_changed_by_late_callbacks(tmp_path, terminal):
    store = Store(tmp_path)
    job, _ = create(store)
    if terminal == "succeeded":
        store.succeed(job["id"], b"first-result")
    else:
        store.fail(job["id"], "first-error", "first-message")
    expected = store.get(job["id"])
    store.update(job["id"], state="running", prompt_id="late-prompt")
    store.succeed(job["id"], b"late-result")
    store.fail(job["id"], "late-error", "late-message")
    assert store.get(job["id"]) == expected
    if terminal == "succeeded":
        assert (store.job_dir(job["id"]) / "result.png").read_bytes() == b"first-result"
    else:
        assert not (store.job_dir(job["id"]) / "result.png").exists()


def test_competing_terminal_results_have_one_winner(tmp_path):
    stores = [Store(tmp_path), Store(tmp_path)]
    job, _ = create(stores[0])
    with ThreadPoolExecutor(max_workers=2) as pool:
        success = pool.submit(stores[0].succeed, job["id"], b"result")
        failure = pool.submit(stores[1].fail, job["id"], "error", "failure")
        success.result()
        failure.result()
    result = stores[0].get(job["id"])
    if result["state"] == "succeeded":
        assert result["error"] is None
        assert result["result_bytes"] == len(b"result")
    else:
        assert result["state"] == "failed"
        assert result["result_bytes"] is None
        assert not (stores[0].job_dir(job["id"]) / "result.png").exists()

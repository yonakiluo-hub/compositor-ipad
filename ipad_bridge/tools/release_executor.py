"""Explicit operator recovery after an ambiguous submission and a confirmed ComfyUI restart.

Stop the bridge first. Restart ComfyUI (losing the old executor), verify no other
user is submitting work, then run with --confirm-comfy-restarted. This never
interrupts a GPU task or changes a job's terminal state.
"""
import argparse
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bridge.app import ProcessLock
from bridge.comfy import ComfyBackend
from bridge.store import Store, JobDeleted


async def release(data_dir, comfy_url, confirmed):
    if not confirmed:
        raise ValueError("Explicit confirmation of a completed ComfyUI restart is required.")
    if not (data_dir / "jobs.sqlite3").is_file():
        raise ValueError("The existing bridge database is required.")
    lock = ProcessLock(data_dir / "server.lock")
    lock.acquire()
    try:
        store = Store(data_dir)
        hold = store.get_hold()
        if not hold:
            return False
        if hold.get("backend_url") is not None and hold["backend_url"] != comfy_url.rstrip("/"):
            raise ValueError("The supplied ComfyUI endpoint does not match the held execution.")
        try:
            if store.get(hold["job_id"])["state"] not in {"succeeded", "failed"}:
                raise ValueError("Recover the active bridge task before releasing its executor.")
        except JobDeleted:
            pass
        async with ComfyBackend(comfy_url, Path(__file__).resolve().parents[1] / "bridge/presets") as backend:
            if not await backend.queue_idle():
                raise ValueError("ComfyUI still has work. No executor was released.")
        return store.release_hold(hold["job_id"])
    finally:
        lock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--comfy-url", default="http://127.0.0.1:8388")
    parser.add_argument("--confirm-comfy-restarted", action="store_true")
    args = parser.parse_args()
    try:
        changed = asyncio.run(release(args.data_dir.resolve(), args.comfy_url, args.confirm_comfy_restarted))
    except (ValueError, RuntimeError, OSError) as exc:
        parser.exit(1, str(exc) + "\n")
    print("Executor released; task states and tombstones preserved." if changed else "No executor hold exists.")


if __name__ == "__main__":
    main()

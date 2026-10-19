"""Launch the existing ComfyUI code with isolated, workspace-owned runtime files."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--install", type=Path, required=True, help="ComfyUI directory containing main.py and .venv")
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8388)
    args = parser.parse_args()
    install, models, runtime = args.install.resolve(), args.models.resolve(), args.runtime.resolve()
    if not (install / "main.py").is_file() or not models.is_dir():
        parser.error("Existing ComfyUI installation and model directory are required")
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{args.port}/system_stats", timeout=2).close()
    except OSError:
        pass
    else:
        parser.error("The target port already runs ComfyUI; reuse it or choose a free port")
    for name in ("input", "output", "temp", "user", "cache"):
        (runtime / name).mkdir(parents=True, exist_ok=True)
    python = install / ".venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    command = [str(python), "-B", "-s", str(install / "main.py"),
               "--listen", "127.0.0.1", "--port", str(args.port), "--disable-auto-launch",
               "--disable-all-custom-nodes", "--disable-api-nodes", "--models-directory", str(models),
               "--input-directory", str(runtime / "input"), "--output-directory", str(runtime / "output"),
               "--temp-directory", str(runtime / "temp"), "--user-directory", str(runtime / "user"),
               "--database-url", "sqlite:///" + (runtime / "user" / "comfyui.db").as_posix()]
    env = os.environ.copy()
    env.pop("SSLKEYLOGFILE", None)
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    for key in ("TMP", "TEMP", "TMPDIR"):
        env[key] = str(runtime / "temp")
    for key in ("CUDA_CACHE_PATH", "TORCHINDUCTOR_CACHE_DIR", "HF_HOME"):
        env[key] = str(runtime / "cache" / key.lower())
    with (runtime / "stdout.log").open("ab") as out, (runtime / "stderr.log").open("ab") as err:
        process = subprocess.Popen(command, cwd=runtime, env=env, stdout=out, stderr=err,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    (runtime / "launch.json").write_text(json.dumps({"pid": process.pid, "port": args.port,
                                                     "install": str(install)}, indent=2), encoding="utf-8")
    print(json.dumps({"pid": process.pid, "port": args.port, "runtime": str(runtime)}))


if __name__ == "__main__":
    main()

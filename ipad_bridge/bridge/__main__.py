import argparse
from pathlib import Path

from .config import Settings


def main():
    parser = argparse.ArgumentParser(description="Local iPad drawing bridge")
    parser.add_argument("command", choices=["serve", "pairing"])
    parser.add_argument("--data-dir", type=Path, default=Path(__file__).resolve().parent.parent / "data")
    parser.add_argument("--backend", choices=["mock", "comfyui"], default="mock")
    parser.add_argument("--comfy-url", default="http://127.0.0.1:8188")
    parser.add_argument("--comfy-models-dir", type=Path, help="Local model root used by this ComfyUI instance")
    parser.add_argument("--comfy-install-dir", type=Path, help="Local ComfyUI source root for immutable dependency checks")
    parser.add_argument("--enable-experimental", action="store_true", help="Allow research/evaluation presets; inspect their license first")
    parser.add_argument("--max-pending-jobs", type=int, default=8)
    parser.add_argument("--max-pending-bytes", type=int, default=256 * 1024 * 1024)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8190)
    parser.add_argument("--base-url", help="Client-facing LAN origin used in the pairing file")
    parser.add_argument("--ssl-certfile")
    parser.add_argument("--ssl-keyfile")
    args = parser.parse_args()
    settings = Settings(args.data_dir, backend=args.backend, comfy_url=args.comfy_url,
                        comfy_models_dir=args.comfy_models_dir, comfy_install_dir=args.comfy_install_dir,
                        enable_experimental=args.enable_experimental, max_pending_jobs=args.max_pending_jobs,
                        max_pending_bytes=args.max_pending_bytes)
    if args.command == "pairing":
        if not args.base_url:
            parser.error("pairing requires --base-url")
        print(f"Pairing file saved: {settings.write_pairing(args.base_url)}")
        return
    if bool(args.ssl_certfile) != bool(args.ssl_keyfile):
        parser.error("TLS requires both --ssl-certfile and --ssl-keyfile")
    settings.token()
    from .app import create_app
    import uvicorn
    uvicorn.run(create_app(settings), host=args.host, port=args.port, workers=1,
                access_log=False, ssl_certfile=args.ssl_certfile, ssl_keyfile=args.ssl_keyfile)


if __name__ == "__main__":
    main()

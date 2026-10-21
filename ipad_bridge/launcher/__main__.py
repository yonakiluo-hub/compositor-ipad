import argparse
import json
from pathlib import Path

from .config import DEFAULT_CONFIG, load_config


def main():
    parser = argparse.ArgumentParser(description="Compositor Windows 服务启动与检查")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--gui", action="store_true", help="打开桌面状态窗口（默认）")
    mode.add_argument("--status", action="store_true", help="只读检查，不启动服务或改写配对")
    mode.add_argument("--start", action="store_true", help="复用或启动服务，输出状态")
    args = parser.parse_args()
    if not args.status and not args.start:
        from .ui import run_ui
        run_ui(args.config)
        return
    from .service import LauncherError, ServiceManager
    try:
        manager = ServiceManager(load_config(args.config))
        result = manager.start() if args.start else manager.status()
    except (ValueError, LauncherError) as error:
        result = {"ready": False, "summary": str(error), "checks": []}
    except OSError:
        result = {"ready": False, "summary": "无法访问文件或启动程序，请检查路径和文件夹权限。", "checks": []}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if not result["ready"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

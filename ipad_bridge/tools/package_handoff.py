"""Build a source handoff archive from an explicit allowlist, without credentials."""
import hashlib
import json
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
workspace = root.parent
destination = workspace / "deliverables" / "Compositor_iPad_Windows_Bridge_v0.1.zip"
destination.parent.mkdir(parents=True, exist_ok=True)
entries = {}

for directory in ("bridge", "tests", "tools", "docs", "examples"):
    for path in (root / directory).rglob("*"):
        if path.is_file() and path.suffix in {".py", ".json", ".md"} and "__pycache__" not in path.parts:
            entries["ipad_bridge/" + path.relative_to(root).as_posix()] = path
for name in ("README.md", "requirements.txt", "requirements-dev.txt", "requirements-lock.txt",
             "pytest.ini", ".gitignore", "setup.ps1", "start-bridge.ps1"):
    entries["ipad_bridge/" + name] = root / name
for name in ("MAC_AGENT_HANDOFF.md", "WINDOWS_BRIDGE_STATUS.md", "PRODUCT_REQUIREMENTS.md"):
    entries["docs/" + name] = workspace / "docs" / name
for name in ("README.md", "AGENTS.md", ".gitignore", ".gitattributes", "THIRD_PARTY_NOTICES.md"):
    entries[name] = workspace / name
entries["docs/GIT_WORKFLOW.md"] = workspace / "docs" / "GIT_WORKFLOW.md"
for path in (workspace / "licenses").glob("*.txt"):
    entries["licenses/" + path.name] = path
entries["ipad_app/README.md"] = workspace / "ipad_app" / "README.md"

manifest = []
with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name, path in sorted(entries.items()):
        if any(part in {".venv", "data", "data-comfyui", "data-mock", "pairing.json", "access-token.txt"}
               for part in Path(name).parts):
            raise RuntimeError("A private runtime path reached the package allowlist")
        content = path.read_bytes()
        archive.writestr(name, content)
        manifest.append({"path": name, "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()})
    archive.writestr("MANIFEST.json", json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
with zipfile.ZipFile(destination) as archive:
    if archive.testzip() is not None:
        raise RuntimeError("Package verification failed")
print(json.dumps({"archive": str(destination), "files": len(entries) + 1,
                  "bytes": destination.stat().st_size,
                  "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()}, ensure_ascii=False))

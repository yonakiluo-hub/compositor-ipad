"""Export the route schema without starting a service or exposing a token."""
import json
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bridge.app import create_app
from bridge.config import Settings

with tempfile.TemporaryDirectory() as directory:
    app = create_app(Settings(Path(directory), start_worker=False))
    output = Path(__file__).resolve().parents[1] / "docs" / "openapi.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(app.openapi(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(output)

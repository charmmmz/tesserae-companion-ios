"""Run Swift's native settings round-trip against an isolated real Python API.

Use the server's Python environment (with its dev dependencies installed):
python Scripts/test_dashboard_native_controls.py --server-repo /path/to/tesserae
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time


def serve(repo: Path, root: Path, config: Path) -> None:
    sys.path.insert(0, str(repo))
    from app.main import create_app
    from app.state.page_store import Page
    from tests.companion.test_dashboard_components import page
    from tests.companion.test_dashboard_native_controls import native_registry
    from werkzeug.serving import make_server

    app = create_app(testing=True, data_root=root / "data")

    class Registry(dict):
        fonts = {}

    app.config["PLUGIN_REGISTRY"] = Registry(native_registry())
    document = page().model_dump(mode="json")
    document.update(id="native-controls-http-qa", name="Native Controls HTTP QA", device_ids=[])
    document["canvas"]["inputs"] = [
        {"name": "mode", "label": "Mode", "targets": [{"el": "one", "key": "title"}]}
    ]
    app.config["PAGE_STORE"].save(Page.model_validate(document))
    token, _ = app.config["COMPANION_TOKENS"].issue(
        client={"name": "Native controls test"}, scopes=["dashboards:read", "dashboards:write"]
    )
    server = make_server("127.0.0.1", 0, app, threaded=True)
    config.write_text(json.dumps({
        "url": f"http://127.0.0.1:{server.server_port}",
        "token": token,
        "dashboardID": document["id"],
    }))
    config.chmod(0o600)
    server.serve_forever()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-repo", required=True, type=Path)
    parser.add_argument("--serve", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--root", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--config", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.serve:
        serve(args.server_repo.resolve(), args.root, args.config)
        return 0
    ios = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="tesserae-native-controls-") as directory:
        root = Path(directory)
        config = root / "connection.json"
        env = dict(os.environ, TESSERAE_SECRET_KEY=secrets.token_hex(32))
        with (root / "server.log").open("w+") as log:
            process = subprocess.Popen([
                sys.executable, __file__, "--serve", "--server-repo", str(args.server_repo.resolve()),
                "--root", str(root), "--config", str(config),
            ], stdout=log, stderr=log, env=env)
            try:
                deadline = time.monotonic() + 20
                while not config.exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise RuntimeError("Isolated API could not start:\n" + log.read())
                    time.sleep(0.1)
                env.update(TESSERAE_NATIVE_CONTROLS_HTTP_TEST="1",
                    TESSERAE_NATIVE_CONTROLS_HTTP_CONFIG=str(config))
                return subprocess.run([
                    "swift", "test", "--package-path", "Packages/TesseraeKit", "--filter",
                    "DashboardNativeSettingsTests/nativeControlsRoundTripThroughPythonServer",
                ], cwd=ios, env=env).returncode
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    raise SystemExit(main())

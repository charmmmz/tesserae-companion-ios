#!/usr/bin/env python3
"""Stateful local server for exercising the proposed Companion contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import threading
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


FIXTURES = Path(__file__).with_name("Fixtures")
FIXTURE_TOKEN = "tc_live_fixture_secret_returned_once"


def load_fixture(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


@dataclass
class FixtureJob:
    accepted: dict[str, Any]
    completed: dict[str, Any]
    fingerprint: str


class FixtureState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.jobs: dict[str, FixtureJob] = {}
        self.jobs_by_key: dict[str, str] = {}
        self.sequence = 0

    def accept_job(
        self,
        *,
        key: str,
        fingerprint: str,
        kind: str,
        label: str,
        device_ids: list[str],
    ) -> tuple[FixtureJob, bool]:
        with self.lock:
            if existing_id := self.jobs_by_key.get(key):
                existing = self.jobs[existing_id]
                return (existing, existing.fingerprint != fingerprint)

            self.sequence += 1
            job_id = f"job_fixture_{self.sequence:04d}"
            accepted = load_fixture("job-accepted.json")
            accepted["job"].update(
                {
                    "id": job_id,
                    "kind": kind,
                    "label": label,
                    "target_device_ids": device_ids,
                }
            )
            completed = load_fixture("job-published.json")
            completed["job"].update(
                {
                    "id": job_id,
                    "kind": kind,
                    "label": label,
                    "target_device_ids": device_ids,
                }
            )
            completed["job"]["result"]["device_ids"] = device_ids
            job = FixtureJob(
                accepted=accepted,
                completed=completed,
                fingerprint=fingerprint,
            )
            self.jobs[job_id] = job
            self.jobs_by_key[key] = job_id
            return (job, False)


class FixtureHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, server_address: tuple[str, int]) -> None:
        super().__init__(server_address, FixtureRequestHandler)
        self.state = FixtureState()


class FixtureRequestHandler(BaseHTTPRequestHandler):
    server: FixtureHTTPServer

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/")
        if path == "/api/app/v1":
            self.send_fixture("capabilities.json")
            return
        if not self.authorized():
            return
        if path == "/api/app/v1/devices":
            self.send_fixture("devices-response.json")
            return
        if path == "/api/app/v1/dashboards":
            self.send_fixture("dashboards-response.json")
            return
        if path.startswith("/api/app/v1/jobs/"):
            job_id = path.rsplit("/", 1)[-1]
            with self.server.state.lock:
                job = self.server.state.jobs.get(job_id)
            if job is None:
                self.send_error_response(
                    HTTPStatus.NOT_FOUND,
                    "not_found",
                    "The requested job does not exist.",
                )
                return
            self.send_json(HTTPStatus.OK, job.completed)
            return
        self.send_error_response(
            HTTPStatus.NOT_FOUND,
            "not_found",
            "The requested Companion resource does not exist.",
        )

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/")
        if path == "/api/app/v1/pair":
            payload = self.read_json()
            code = str(payload.get("code", "")) if payload else ""
            if len(code) != 6 or not code.isdigit():
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "pairing_expired",
                    "Enter a valid six-digit fixture pairing code.",
                )
                return
            self.send_fixture("pair-response.json", status=HTTPStatus.CREATED)
            return

        if not self.authorized():
            return
        if path.startswith("/api/app/v1/dashboards/") and path.endswith("/push"):
            payload = self.read_json()
            if payload is None:
                return
            dashboard_id = path.split("/")[-2]
            device_ids = payload.get("device_ids") or ["picpak-kitchen"]
            self.accept_job(
                kind="dashboard_push",
                label=dashboard_id.replace("-", " ").title(),
                device_ids=device_ids,
                body=json.dumps(payload, sort_keys=True).encode(),
            )
            return
        if path == "/api/app/v1/images":
            content_type = self.headers.get("Content-Type", "")
            body = self.read_body()
            if "multipart/form-data" not in content_type:
                self.send_error_response(
                    HTTPStatus.UNSUPPORTED_MEDIA_TYPE,
                    "unsupported_image",
                    "Expected a multipart image request.",
                )
                return
            if b'name="request"' not in body or b'name="image"' not in body:
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    "Both request and image parts are required.",
                )
                return
            self.accept_job(
                kind="image_push",
                label="Shared Photo",
                device_ids=["picpak-kitchen"],
                body=body,
            )
            return
        self.send_error_response(
            HTTPStatus.NOT_FOUND,
            "not_found",
            "The requested Companion resource does not exist.",
        )

    def do_DELETE(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/")
        if path == "/api/app/v1/session":
            if not self.authorized():
                return
            self.send_response(HTTPStatus.NO_CONTENT)
            self.end_headers()
            return
        self.send_error_response(
            HTTPStatus.NOT_FOUND,
            "not_found",
            "The requested Companion resource does not exist.",
        )

    def accept_job(
        self,
        *,
        kind: str,
        label: str,
        device_ids: list[str],
        body: bytes,
    ) -> None:
        key = self.headers.get("Idempotency-Key", "")
        if len(key) < 16:
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "Idempotency-Key must contain at least 16 characters.",
            )
            return
        fingerprint = hashlib.sha256(body).hexdigest()
        job, conflict = self.server.state.accept_job(
            key=key,
            fingerprint=fingerprint,
            kind=kind,
            label=label,
            device_ids=device_ids,
        )
        if conflict:
            self.send_fixture("error-response.json", status=HTTPStatus.CONFLICT)
            return
        self.send_json(
            HTTPStatus.ACCEPTED,
            job.accepted,
            headers={
                "Location": f"/api/app/v1/jobs/{job.accepted['job']['id']}",
                "Retry-After": "1",
            },
        )

    def authorized(self) -> bool:
        if self.headers.get("Authorization") == f"Bearer {FIXTURE_TOKEN}":
            return True
        self.send_error_response(
            HTTPStatus.UNAUTHORIZED,
            "unauthorized",
            "A valid fixture Companion credential is required.",
        )
        return False

    def read_body(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        return self.rfile.read(length)

    def read_json(self) -> dict[str, Any] | None:
        try:
            return json.loads(self.read_body())
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "The JSON request body is invalid.",
            )
            return None

    def send_fixture(
        self,
        name: str,
        *,
        status: HTTPStatus = HTTPStatus.OK,
    ) -> None:
        self.send_json(status, load_fixture(name))

    def send_error_response(
        self,
        status: HTTPStatus,
        code: str,
        message: str,
    ) -> None:
        self.send_json(
            status,
            {
                "error": {
                    "code": code,
                    "message": message,
                    "request_id": "req_fixture",
                }
            },
        )

    def send_json(
        self,
        status: HTTPStatus,
        payload: dict[str, Any],
        *,
        headers: dict[str, str] | None = None,
    ) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    server = FixtureHTTPServer((args.host, args.port))
    host, port = server.server_address[:2]
    print(f"http://{host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

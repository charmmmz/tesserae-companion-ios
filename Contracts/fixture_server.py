#!/usr/bin/env python3
"""Stateful local server for exercising the proposed Companion contract."""

from __future__ import annotations

import argparse
import base64
import hashlib
import ipaddress
import json
import threading
from dataclasses import dataclass
from email.parser import BytesParser
from email.policy import default as email_policy
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


FIXTURES = Path(__file__).with_name("Fixtures")
FIXTURE_TOKEN = "tc_live_fixture_secret_returned_once"
FIXTURE_PREVIEW_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC"
    "AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


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
            if kind in {"history_resend", "image_url_push", "webpage_push"}:
                completed["job"]["result"]["history_event_ids"] = [
                    f"history_fixture_{self.sequence:04d}"
                ]
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
            self.send_fixture("capabilities-framing.json")
            return
        if not self.authorized():
            return
        if path == "/api/app/v1/devices":
            self.send_fixture("devices-response.json")
            return
        if path == "/api/app/v1/dashboards":
            self.send_fixture("dashboards-response.json")
            return
        if path == "/api/app/v1/history":
            self.send_fixture("history-response.json")
            return
        if path.startswith("/api/app/v1/history/") and path.endswith("/preview"):
            history_id = path.split("/")[-2]
            if history_id not in {"history_0101", "history_0102"}:
                self.send_error_response(
                    HTTPStatus.NOT_FOUND,
                    "not_found",
                    "The requested History preview does not exist.",
                )
                return
            preview_etag = '"history-preview-fixture"'
            if self.headers.get("If-None-Match") == preview_etag:
                self.send_response(HTTPStatus.NOT_MODIFIED)
                self.send_header("ETag", preview_etag)
                self.end_headers()
                return
            self.send_bytes(
                HTTPStatus.OK,
                FIXTURE_PREVIEW_PNG,
                content_type="image/png",
                headers={
                    "ETag": preview_etag,
                    "Cache-Control": "private, no-cache",
                },
            )
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
            payload = self.parse_image_multipart(content_type, body)
            if payload is None:
                return
            device_ids = self.validate_image_push_payload(payload)
            if device_ids is None:
                return
            self.accept_job(
                kind="image_push",
                label="Shared Photo",
                device_ids=device_ids,
                body=body,
            )
            return
        if path in {"/api/app/v1/image-urls", "/api/app/v1/webpages"}:
            payload = self.read_json()
            if payload is None:
                return
            validated = self.validate_link_push_payload(
                payload,
                allow_viewport=path == "/api/app/v1/webpages",
            )
            if validated is None:
                return
            url, device_ids = validated
            parsed = urlparse(url)
            label = f"{parsed.hostname or ''}{parsed.path or '/'}"
            self.accept_job(
                kind=(
                    "webpage_push"
                    if path == "/api/app/v1/webpages"
                    else "image_url_push"
                ),
                label=label,
                device_ids=device_ids,
                body=json.dumps(payload, sort_keys=True).encode(),
            )
            return
        if path.startswith("/api/app/v1/history/") and path.endswith("/resend"):
            payload = self.read_json()
            if payload is None:
                return
            history_id = path.split("/")[-2]
            if history_id not in {"history_0101", "history_0102"}:
                self.send_error_response(
                    HTTPStatus.NOT_FOUND,
                    "not_found",
                    "The requested History row does not exist.",
                )
                return
            if not isinstance(payload.get("override_quiet_hours"), bool):
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    "override_quiet_hours is required.",
                )
                return
            self.accept_job(
                kind="history_resend",
                label="Shared Photo" if history_id == "history_0102" else "Pantry",
                device_ids=(
                    ["e1004-desk"]
                    if history_id == "history_0102"
                    else ["picpak-kitchen"]
                ),
                body=json.dumps(payload, sort_keys=True).encode(),
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

    def validate_link_push_payload(
        self,
        payload: dict[str, Any],
        *,
        allow_viewport: bool,
    ) -> tuple[str, list[str]] | None:
        allowed_keys = {
            "url",
            "device_ids",
            "fit",
            "override_quiet_hours",
        }
        if allow_viewport:
            allowed_keys.add("viewport_w")
        if unknown_keys := set(payload).difference(allowed_keys):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                f"Unexpected request fields: {', '.join(sorted(unknown_keys))}.",
            )
            return None

        url = payload.get("url")
        if not isinstance(url, str):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "A public HTTP(S) URL is required.",
            )
            return None
        parsed = urlparse(url)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
        ):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "url_blocked",
                "The URL must be public HTTP(S) without embedded credentials.",
            )
            return None
        if self.fixture_host_is_blocked(parsed.hostname):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "url_blocked",
                "The URL is not permitted by the Companion network policy.",
            )
            return None

        device_ids = payload.get("device_ids")
        if (
            not isinstance(device_ids, list)
            or not device_ids
            or any(not isinstance(item, str) or not item for item in device_ids)
            or len(set(device_ids)) != len(device_ids)
        ):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_target",
                "Select one or more unique display targets.",
            )
            return None

        if payload.get("fit") not in {"fit", "fill", "blur", "stretch", "center"}:
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "Choose a server-advertised image fit mode.",
            )
            return None
        if not isinstance(payload.get("override_quiet_hours"), bool):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "override_quiet_hours is required.",
            )
            return None

        if allow_viewport and "viewport_w" in payload:
            viewport_w = payload["viewport_w"]
            if (
                not isinstance(viewport_w, int)
                or isinstance(viewport_w, bool)
                or not 200 <= viewport_w <= 4096
            ):
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    "viewport_w must be between 200 and 4096.",
                )
                return None

        return url, device_ids

    def parse_image_multipart(
        self,
        content_type: str,
        body: bytes,
    ) -> dict[str, Any] | None:
        envelope = (
            f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode()
            + body
        )
        message = BytesParser(policy=email_policy).parsebytes(envelope)
        if not message.is_multipart():
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "The multipart image request is invalid.",
            )
            return None

        request_payload: dict[str, Any] | None = None
        has_image = False
        for part in message.iter_parts():
            name = part.get_param("name", header="content-disposition")
            part_body = part.get_payload(decode=True) or b""
            if name == "image":
                has_image = bool(part_body)
            elif name == "request":
                try:
                    decoded = json.loads(part_body)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    decoded = None
                if isinstance(decoded, dict):
                    request_payload = decoded

        if not has_image or request_payload is None:
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "Both request and image parts are required.",
            )
            return None
        return request_payload

    def validate_image_push_payload(
        self,
        payload: dict[str, Any],
    ) -> list[str] | None:
        allowed_keys = {
            "device_ids",
            "fit",
            "framing",
            "override_quiet_hours",
        }
        if unknown_keys := set(payload).difference(allowed_keys):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                f"Unexpected request fields: {', '.join(sorted(unknown_keys))}.",
            )
            return None

        device_ids = payload.get("device_ids")
        if (
            not isinstance(device_ids, list)
            or not device_ids
            or any(not isinstance(item, str) or not item for item in device_ids)
            or len(set(device_ids)) != len(device_ids)
        ):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_target",
                "Select one or more unique display targets.",
            )
            return None

        fit = payload.get("fit")
        if fit not in {"fit", "fill", "blur", "stretch", "center"}:
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "Choose a server-advertised image fit mode.",
            )
            return None
        if not isinstance(payload.get("override_quiet_hours"), bool):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "override_quiet_hours is required.",
            )
            return None

        framing = payload.get("framing")
        if framing is None:
            return device_ids
        if fit != "fill" or not isinstance(framing, dict):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_framing",
                "Image framing is accepted only with Fill.",
            )
            return None
        if set(framing) != {"focus_x", "focus_y", "zoom"}:
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_framing",
                "Framing requires only focus_x, focus_y, and zoom.",
            )
            return None

        focus_x = framing.get("focus_x")
        focus_y = framing.get("focus_y")
        zoom = framing.get("zoom")
        values = (focus_x, focus_y, zoom)
        if any(
            not isinstance(value, (int, float)) or isinstance(value, bool)
            for value in values
        ):
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_framing",
                "Framing values must be numbers.",
            )
            return None
        if not 0 <= focus_x <= 1 or not 0 <= focus_y <= 1 or not 1 <= zoom <= 8:
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_framing",
                "Framing exceeds the advertised normalized focus or zoom limits.",
            )
            return None
        return device_ids

    @staticmethod
    def fixture_host_is_blocked(host: str) -> bool:
        """Mirror obvious strict-policy cases without performing DNS in fixtures."""
        if host.lower() in {"localhost", "localhost.localdomain"}:
            return True
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            return False
        return bool(
            address.is_loopback
            or address.is_private
            or address.is_link_local
            or address.is_reserved
            or address.is_multicast
            or address.is_unspecified
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

    def send_bytes(
        self,
        status: HTTPStatus,
        body: bytes,
        *,
        content_type: str,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
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

#!/usr/bin/env python3
"""Stateful local server for exercising the proposed Companion contract."""

from __future__ import annotations

import argparse
import base64
import hashlib
import ipaddress
import json
import re
import threading
from dataclasses import dataclass
from email.parser import BytesParser
from email.policy import default as email_policy
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


FIXTURES = Path(__file__).with_name("Fixtures")
FIXTURE_TOKEN = "tc_live_fixture_secret_returned_once"
FIXTURE_PREVIEW_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC"
    "AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def load_fixture(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def advertised_image_framing_max_zoom() -> float:
    capabilities = load_fixture("capabilities-framing.json")
    return float(capabilities["limits"]["image_framing_max_zoom"])


def normalize_gallery_folder_name(raw: str) -> str | None:
    """Mirror the Gallery adapter's storage-name ownership for fixtures."""
    folded = re.sub(r"[^a-z0-9_-]+", "-", raw.strip().lower()).strip("-_")
    folded = re.sub(r"-{2,}", "-", folded)[:64].strip("-_")
    return folded or None


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
        self.lineups = {
            lineup["id"]: lineup
            for lineup in load_fixture("lineups-response.json")["lineups"]
        }
        self.gallery_folders = {
            folder["id"]: folder
            for folder in load_fixture("gallery-folders-response.json")["folders"]
        }
        family = load_fixture("gallery-folder-response.json")
        archive = load_fixture("gallery-external-folder-response.json")
        self.gallery_images_by_folder = {
            folder_id: [] for folder_id in self.gallery_folders
        }
        self.gallery_images_by_folder[family["folder"]["id"]] = family["images"]
        self.gallery_images_by_folder[archive["folder"]["id"]] = archive["images"]
        self.gallery_images = {
            image["id"]: image
            for image in [*family["images"], *archive["images"]]
        }
        self.gallery_image_blobs = {
            image_id: FIXTURE_PREVIEW_PNG for image_id in self.gallery_images
        }
        self.gallery_uploads_by_key: dict[str, tuple[str, dict[str, Any]]] = {}
        self.gallery_folder_sequence = 0
        self.gallery_sequence = 0

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
            if kind in {
                "history_resend",
                "image_url_push",
                "webpage_push",
                "lineup_action",
            }:
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
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        if path == "/api/app/v1":
            self.send_fixture("capabilities-timeline.json")
            return
        if not self.authorized():
            return
        if path == "/api/app/v1/devices":
            self.send_fixture("devices-gallery-response.json")
            return
        upcoming_match = re.fullmatch(
            r"/api/app/v1/devices/([^/]+)/upcoming",
            path,
        )
        if upcoming_match:
            if upcoming_match.group(1) != "picpak-kitchen":
                self.send_error_response(
                    HTTPStatus.NOT_FOUND,
                    "not_found",
                    "The requested display does not exist.",
                )
                return
            query = parse_qs(parsed.query)
            try:
                hours = int(query.get("hours", ["24"])[0])
                limit = int(query.get("limit", ["6"])[0])
            except ValueError:
                hours = 0
                limit = 0
            if not 1 <= hours <= 168 or not 1 <= limit <= 20:
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    "Timeline hours or limit is outside the advertised bounds.",
                )
                return
            response = load_fixture("device-upcoming-response.json")
            response["events"] = response["events"][:limit]
            self.send_json(HTTPStatus.OK, response)
            return
        if path == "/api/app/v1/gallery/folders":
            with self.server.state.lock:
                folders = list(self.server.state.gallery_folders.values())
            self.send_json(HTTPStatus.OK, {"folders": folders})
            return
        if path.startswith("/api/app/v1/gallery/folders/"):
            folder_id = path.rsplit("/", 1)[-1]
            with self.server.state.lock:
                folder = self.server.state.gallery_folders.get(folder_id)
                images = list(
                    self.server.state.gallery_images_by_folder.get(folder_id, [])
                )
            if folder is None:
                self.send_error_response(
                    HTTPStatus.NOT_FOUND,
                    "not_found",
                    "The requested Gallery folder does not exist.",
                )
                return
            self.send_json(HTTPStatus.OK, {"folder": folder, "images": images})
            return
        if path.startswith("/api/app/v1/gallery/images/") and path.endswith(
            ("/thumbnail", "/content")
        ):
            image_id = path.split("/")[-2]
            with self.server.state.lock:
                image = self.server.state.gallery_images.get(image_id)
                blob = self.server.state.gallery_image_blobs.get(image_id)
            if image is None or blob is None:
                self.send_error_response(
                    HTTPStatus.NOT_FOUND,
                    "not_found",
                    "The requested Gallery image does not exist.",
                )
                return
            thumbnail = path.endswith("/thumbnail")
            etag = (
                f'"{image_id}-thumbnail"' if thumbnail else str(image["etag"])
            )
            if self.headers.get("If-None-Match") == etag:
                self.send_response(HTTPStatus.NOT_MODIFIED)
                self.send_header("ETag", etag)
                self.end_headers()
                return
            headers = {"ETag": etag, "Cache-Control": "private, no-cache"}
            if not thumbnail:
                headers["Content-Disposition"] = f'inline; filename="{image["name"]}"'
            self.send_bytes(
                HTTPStatus.OK,
                FIXTURE_PREVIEW_PNG if thumbnail else blob,
                content_type="image/png" if thumbnail else str(image["content_type"]),
                headers=headers,
            )
            return
        if path == "/api/app/v1/dashboards":
            self.send_fixture("dashboards-response.json")
            return
        if path == "/api/app/v1/history":
            self.send_fixture("history-response.json")
            return
        if path == "/api/app/v1/lineups":
            with self.server.state.lock:
                lineups = list(self.server.state.lineups.values())
            self.send_json(HTTPStatus.OK, {"lineups": lineups})
            return
        if path.startswith("/api/app/v1/lineups/"):
            lineup_id = path.rsplit("/", 1)[-1]
            with self.server.state.lock:
                lineup = self.server.state.lineups.get(lineup_id)
            if lineup is None:
                self.send_error_response(
                    HTTPStatus.NOT_FOUND,
                    "not_found",
                    "The requested Lineup does not exist.",
                )
                return
            self.send_json(
                HTTPStatus.OK,
                {"lineup": lineup},
            )
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
            self.send_fixture("pair-response-gallery.json", status=HTTPStatus.CREATED)
            return

        if not self.authorized():
            return
        if path == "/api/app/v1/gallery/folders":
            payload = self.read_json()
            if payload is None:
                return
            if set(payload) != {"name"} or not isinstance(payload.get("name"), str):
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    "A Gallery folder name is required.",
                )
                return
            requested_name = payload["name"].strip()
            if not requested_name or len(requested_name) > 80:
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    "Gallery folder names must contain 1 to 80 characters.",
                )
                return
            name = normalize_gallery_folder_name(requested_name)
            if name is None:
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    "The Gallery folder name has no usable letters or digits.",
                )
                return
            with self.server.state.lock:
                conflict = any(
                    folder["name"] == name
                    for folder in self.server.state.gallery_folders.values()
                )
                if not conflict:
                    self.server.state.gallery_folder_sequence += 1
                    folder_id = (
                        "folder_created_"
                        f"{self.server.state.gallery_folder_sequence:04d}"
                    )
                    folder = {
                        "id": folder_id,
                        "name": name,
                        "kind": "internal",
                        "writable": True,
                        "image_count": 0,
                        "cover_thumbnail_url": None,
                    }
                    self.server.state.gallery_folders[folder_id] = folder
                    self.server.state.gallery_images_by_folder[folder_id] = []
            if conflict:
                self.send_error_response(
                    HTTPStatus.CONFLICT,
                    "resource_conflict",
                    "A Gallery folder with that normalized name already exists.",
                )
                return
            self.send_json(
                HTTPStatus.CREATED,
                {"folder": folder, "images": []},
            )
            return
        if path.startswith("/api/app/v1/gallery/folders/") and path.endswith(
            "/images"
        ):
            folder_id = path.split("/")[-2]
            content_type = self.headers.get("Content-Type", "")
            body = self.read_body()
            if "multipart/form-data" not in content_type:
                self.send_error_response(
                    HTTPStatus.UNSUPPORTED_MEDIA_TYPE,
                    "unsupported_image",
                    "Expected one multipart Gallery image.",
                )
                return
            upload = self.parse_gallery_image_multipart(content_type, body)
            if upload is None:
                return
            self.accept_gallery_upload(folder_id=folder_id, upload=upload)
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
        if path.startswith("/api/app/v1/lineups/") and path.endswith("/actions"):
            payload = self.read_json()
            if payload is None:
                return
            lineup_id = path.split("/")[-2]
            with self.server.state.lock:
                lineup = self.server.state.lineups.get(lineup_id)
            if lineup is None:
                self.send_error_response(
                    HTTPStatus.NOT_FOUND,
                    "not_found",
                    "The requested Lineup does not exist.",
                )
                return
            action = payload.get("action")
            if action not in {"enable", "disable", "next", "previous", "play"}:
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    "action must be enable, disable, next, previous, or play.",
                )
                return
            if action in {"enable", "disable"}:
                if set(payload) != {"action"}:
                    self.send_error_response(
                        HTTPStatus.BAD_REQUEST,
                        "invalid_request",
                        "State actions accept only action.",
                    )
                    return
                with self.server.state.lock:
                    lineup["enabled"] = action == "enable"
                    updated = dict(lineup)
                self.send_json(HTTPStatus.OK, {"lineup": updated})
                return

            allowed_keys = {"action", "page_id", "device_ids", "override_quiet_hours"}
            if unknown_keys := set(payload).difference(allowed_keys):
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    f"Unexpected request fields: {', '.join(sorted(unknown_keys))}.",
                )
                return
            page_id = payload.get("page_id")
            dashboard_ids = [item["page_id"] for item in lineup["dashboards"]]
            if action == "play":
                if page_id not in dashboard_ids:
                    self.send_error_response(
                        HTTPStatus.BAD_REQUEST,
                        "invalid_request",
                        "play requires a page_id from this Lineup.",
                    )
                    return
            elif page_id is not None:
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    "page_id is accepted only for play.",
                )
                return
            if not isinstance(payload.get("override_quiet_hours"), bool):
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_request",
                    "override_quiet_hours is required.",
                )
                return
            device_ids = payload.get("device_ids", lineup["device_ids"])
            if (
                not isinstance(device_ids, list)
                or not device_ids
                or any(not isinstance(item, str) or not item for item in device_ids)
                or len(set(device_ids)) != len(device_ids)
                or not set(device_ids).issubset(set(lineup["device_ids"]))
            ):
                self.send_error_response(
                    HTTPStatus.BAD_REQUEST,
                    "invalid_target",
                    "Targets must be displays bound to this Lineup.",
                )
                return

            with self.server.state.lock:
                current_by_device = {
                    item["device_id"]: item["page_id"] for item in lineup["current"]
                }
                for device_id in device_ids:
                    if action == "play":
                        target_page = page_id
                    else:
                        current_page = current_by_device.get(device_id)
                        try:
                            current_index = dashboard_ids.index(current_page)
                        except ValueError:
                            current_index = 0
                        step = 1 if action == "next" else -1
                        target_page = dashboard_ids[
                            (current_index + step) % len(dashboard_ids)
                        ]
                    current_by_device[device_id] = target_page
                lineup["current"] = [
                    {"device_id": device_id, "page_id": current_page}
                    for device_id, current_page in current_by_device.items()
                ]
            self.accept_job(
                kind="lineup_action",
                label=lineup["name"],
                device_ids=device_ids,
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

    def accept_gallery_upload(
        self,
        *,
        folder_id: str,
        upload: dict[str, Any],
    ) -> None:
        with self.server.state.lock:
            folder = self.server.state.gallery_folders.get(folder_id)
        if folder is None:
            self.send_error_response(
                HTTPStatus.NOT_FOUND,
                "not_found",
                "The requested Gallery folder does not exist.",
            )
            return
        if not folder["writable"]:
            self.send_error_response(
                HTTPStatus.CONFLICT,
                "resource_conflict",
                "This Gallery folder is read-only.",
            )
            return

        capabilities = load_fixture("capabilities-gallery.json")
        limits = capabilities["limits"]
        if upload["content_type"] not in limits["gallery_image_content_types"]:
            self.send_error_response(
                HTTPStatus.UNSUPPORTED_MEDIA_TYPE,
                "unsupported_image",
                "The Gallery image type is not advertised by this server.",
            )
            return
        if len(upload["data"]) > limits["gallery_upload_bytes"]:
            self.send_error_response(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                "image_too_large",
                "The Gallery image exceeds the advertised byte limit.",
            )
            return

        key = self.headers.get("Idempotency-Key", "")
        if len(key) < 16:
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "Idempotency-Key must contain at least 16 characters.",
            )
            return
        fingerprint = hashlib.sha256(
            b"\0".join(
                [
                    folder_id.encode(),
                    str(upload["content_type"]).encode(),
                    str(upload["filename"]).encode(),
                    upload["data"],
                ]
            )
        ).hexdigest()

        with self.server.state.lock:
            existing = self.server.state.gallery_uploads_by_key.get(key)
            if existing is not None:
                existing_fingerprint, image = existing
                conflict = existing_fingerprint != fingerprint
            else:
                conflict = False
                self.server.state.gallery_sequence += 1
                image_id = f"image_upload_{self.server.state.gallery_sequence:04d}"
                source_name = Path(str(upload["filename"])).name
                source_stem = Path(source_name).stem or "upload"
                stored_content_type = (
                    "image/jpeg"
                    if upload["content_type"] in {"image/heic", "image/heif"}
                    else upload["content_type"]
                )
                stored_suffix = {
                    "image/jpeg": ".jpg",
                    "image/png": ".png",
                    "image/webp": ".webp",
                }[stored_content_type]
                safe_name = f"{source_stem}{stored_suffix}"
                image = {
                    "id": image_id,
                    "folder_id": folder_id,
                    "name": safe_name,
                    "content_type": stored_content_type,
                    "bytes": len(upload["data"]),
                    "width": 1600,
                    "height": 1200,
                    "etag": f'"{fingerprint[:16]}"',
                    "thumbnail_url": (
                        f"/api/app/v1/gallery/images/{image_id}/thumbnail"
                    ),
                    "content_url": f"/api/app/v1/gallery/images/{image_id}/content",
                    "created_at": "2026-08-14T08:30:00Z",
                }
                self.server.state.gallery_uploads_by_key[key] = (fingerprint, image)
                self.server.state.gallery_images[image_id] = image
                self.server.state.gallery_image_blobs[image_id] = upload["data"]
                self.server.state.gallery_images_by_folder[folder_id].append(image)
                folder["image_count"] = len(
                    self.server.state.gallery_images_by_folder[folder_id]
                )
                if folder["cover_thumbnail_url"] is None:
                    folder["cover_thumbnail_url"] = image["thumbnail_url"]
        if conflict:
            self.send_error_response(
                HTTPStatus.CONFLICT,
                "idempotency_conflict",
                "The Idempotency-Key was already used with another image.",
            )
            return
        self.send_json(
            HTTPStatus.CREATED,
            {"image": image},
            headers={"Location": image["content_url"], "ETag": image["etag"]},
        )

    def parse_gallery_image_multipart(
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
                "The multipart Gallery request is invalid.",
            )
            return None

        images: list[dict[str, Any]] = []
        unexpected = False
        for part in message.iter_parts():
            name = part.get_param("name", header="content-disposition")
            if name != "image":
                unexpected = True
                continue
            data = part.get_payload(decode=True) or b""
            images.append(
                {
                    "filename": part.get_filename() or "upload.jpg",
                    "content_type": part.get_content_type(),
                    "data": data,
                }
            )
        if unexpected or len(images) != 1 or not images[0]["data"]:
            self.send_error_response(
                HTTPStatus.BAD_REQUEST,
                "invalid_request",
                "Exactly one non-empty Gallery image part is required.",
            )
            return None
        return images[0]

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
        max_zoom = advertised_image_framing_max_zoom()
        if (
            not 0 <= focus_x <= 1
            or not 0 <= focus_y <= 1
            or not 1 <= zoom <= max_zoom
        ):
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

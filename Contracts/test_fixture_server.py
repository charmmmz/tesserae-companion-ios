from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request

from fixture_server import FIXTURE_TOKEN, FixtureHTTPServer


def request(
    base_url: str,
    path: str,
    *,
    method: str = "GET",
    payload: dict | None = None,
    token: str | None = None,
    idempotency_key: str | None = None,
) -> tuple[int, dict | None]:
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Accept": "application/json"}
    if payload is not None:
        headers["Content-Type"] = "application/json"
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    if idempotency_key is not None:
        headers["Idempotency-Key"] = idempotency_key
    prepared = urllib.request.Request(
        f"{base_url}{path}",
        data=data,
        headers=headers,
        method=method,
    )
    try:
        response = urllib.request.urlopen(prepared, timeout=2)
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())
    body = response.read()
    return response.status, json.loads(body) if body else None


def image_request(
    base_url: str,
    payload: dict,
    *,
    token: str,
    idempotency_key: str,
) -> tuple[int, dict | None]:
    boundary = "TesseraeFixtureBoundary"
    metadata = json.dumps(payload, separators=(",", ":")).encode()
    body = b"".join(
        [
            f"--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="request"\r\n',
            b"Content-Type: application/json\r\n\r\n",
            metadata,
            b"\r\n",
            f"--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="image"; filename="fixture.jpg"\r\n',
            b"Content-Type: image/jpeg\r\n\r\n",
            b"fixture-image",
            b"\r\n",
            f"--{boundary}--\r\n".encode(),
        ]
    )
    prepared = urllib.request.Request(
        f"{base_url}/api/app/v1/images",
        data=body,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Idempotency-Key": idempotency_key,
        },
        method="POST",
    )
    try:
        response = urllib.request.urlopen(prepared, timeout=2)
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())
    response_body = response.read()
    return response.status, json.loads(response_body) if response_body else None


def gallery_image_request(
    base_url: str,
    folder_id: str,
    *,
    token: str,
    idempotency_key: str,
    image: bytes = b"fixture-gallery-image",
    filename: str = "beach.jpg",
    content_type: str = "image/jpeg",
) -> tuple[int, dict | None]:
    boundary = "TesseraeGalleryFixtureBoundary"
    body = b"".join(
        [
            f"--{boundary}\r\n".encode(),
            (
                'Content-Disposition: form-data; name="image"; '
                f'filename="{filename}"\r\n'
            ).encode(),
            f"Content-Type: {content_type}\r\n\r\n".encode(),
            image,
            b"\r\n",
            f"--{boundary}--\r\n".encode(),
        ]
    )
    prepared = urllib.request.Request(
        f"{base_url}/api/app/v1/gallery/folders/{folder_id}/images",
        data=body,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Idempotency-Key": idempotency_key,
        },
        method="POST",
    )
    try:
        response = urllib.request.urlopen(prepared, timeout=2)
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())
    response_body = response.read()
    return response.status, json.loads(response_body) if response_body else None


def test_fixture_server_exercises_companion_vertical_slice():
    server = FixtureHTTPServer(("127.0.0.1", 0))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f"http://127.0.0.1:{server.server_port}"

    try:
        status, capabilities = request(base_url, "/api/app/v1")
        assert status == 200
        assert capabilities["api"]["version"] == 1
        assert capabilities["limits"]["image_fit_modes"] == [
            "fit",
            "fill",
            "blur",
            "stretch",
            "center",
        ]
        assert capabilities["limits"]["image_framing_max_zoom"] == 4
        framing_max_zoom = capabilities["limits"]["image_framing_max_zoom"]
        assert "image_framing" in capabilities["features"]
        assert "history" in capabilities["features"]
        assert "image_url_push" in capabilities["features"]
        assert "webpage_push" in capabilities["features"]
        assert "lineups" in capabilities["features"]
        assert "lineup_control" in capabilities["features"]
        assert "gallery" in capabilities["features"]
        assert capabilities["limits"]["gallery_upload_bytes"] == 20 * 1024 * 1024
        assert capabilities["limits"]["gallery_upload_batch_size"] == 20
        assert "device_timeline" in capabilities["features"]
        assert capabilities["limits"]["device_timeline_max_hours"] == 168
        assert capabilities["limits"]["device_timeline_max_events"] == 20

        status, pair = request(
            base_url,
            "/api/app/v1/pair",
            method="POST",
            payload={
                "code": "482193",
                "client": {
                    "name": "Test iPhone",
                    "platform": "ios",
                    "app_version": "0.1.0",
                    "installation_id": "test-installation-0001",
                },
            },
        )
        assert status == 201
        assert pair["token"] == FIXTURE_TOKEN
        assert "lineups:read" in pair["scopes"]
        assert "lineups:control" in pair["scopes"]
        assert "gallery:read" in pair["scopes"]
        assert "gallery:write" in pair["scopes"]

        status, upcoming = request(
            base_url,
            "/api/app/v1/devices/picpak-kitchen/upcoming?hours=24&limit=1",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert upcoming["device_id"] == "picpak-kitchen"
        assert len(upcoming["events"]) == 1
        assert upcoming["events"][0]["cause"] == "cycle"

        status, invalid_upcoming = request(
            base_url,
            "/api/app/v1/devices/picpak-kitchen/upcoming?hours=169",
            token=FIXTURE_TOKEN,
        )
        assert status == 400
        assert invalid_upcoming["error"]["code"] == "invalid_request"

        status, devices = request(
            base_url,
            "/api/app/v1/devices",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert devices["devices"][0]["id"] == "picpak-kitchen"
        assert devices["devices"][0]["capability_support"]["frame_cache"][
            "state"
        ] == "unsupported"
        assert devices["devices"][1]["capability_support"]["frame_cache"][
            "state"
        ] == "supported"
        assert devices["devices"][2]["capability_support"]["frame_cache"][
            "state"
        ] == "unknown"
        assert devices["devices"][3]["capability_support"]["frame_cache"] == {
            "state": "unknown",
            "reason_code": "stale_heartbeat",
            "observed_at": "2026-08-13T20:00:00Z",
        }

        status, gallery_folders = request(
            base_url,
            "/api/app/v1/gallery/folders",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert gallery_folders["folders"][0]["name"] == "family"
        external = next(
            folder
            for folder in gallery_folders["folders"]
            if folder["kind"] == "external"
        )
        assert external["writable"] is False
        assert "external_path" not in external

        status, external_folder = request(
            base_url,
            "/api/app/v1/gallery/folders/folder_nas_archive",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert external_folder["images"][0]["id"] == "image_archive_01"

        status, gallery_folder = request(
            base_url,
            "/api/app/v1/gallery/folders/folder_family",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert [image["id"] for image in gallery_folder["images"]] == [
            "image_family_01",
            "image_family_02",
            "image_family_03",
            "image_family_04",
        ]
        assert [image["content_type"] for image in gallery_folder["images"]] == [
            "image/png",
            "image/jpeg",
            "image/gif",
            "image/bmp",
        ]

        status, created_folder = request(
            base_url,
            "/api/app/v1/gallery/folders",
            method="POST",
            payload={"name": "Summer 2026!"},
            token=FIXTURE_TOKEN,
        )
        assert status == 201
        assert created_folder == {
            "folder": {
                "id": "folder_created_0001",
                "name": "summer-2026",
                "kind": "internal",
                "writable": True,
                "image_count": 0,
                "cover_thumbnail_url": None,
            },
            "images": [],
        }

        status, folder_conflict = request(
            base_url,
            "/api/app/v1/gallery/folders",
            method="POST",
            payload={"name": "  SUMMER   2026  "},
            token=FIXTURE_TOKEN,
        )
        assert status == 409
        assert folder_conflict["error"]["code"] == "resource_conflict"

        gallery_key = "fixture-gallery-upload-0001"
        status, uploaded = gallery_image_request(
            base_url,
            "folder_family",
            token=FIXTURE_TOKEN,
            idempotency_key=gallery_key,
        )
        assert status == 201
        assert uploaded["image"]["folder_id"] == "folder_family"
        assert uploaded["image"]["name"] == "beach.jpg"

        status, normalized_upload = gallery_image_request(
            base_url,
            "folder_family",
            token=FIXTURE_TOKEN,
            idempotency_key="fixture-gallery-heic-0001",
            image=b"fixture-heic-image",
            filename="portrait.heic",
            content_type="image/heic",
        )
        assert status == 201
        assert normalized_upload["image"]["name"] == "portrait.jpg"
        assert normalized_upload["image"]["content_type"] == "image/jpeg"

        status, unsupported_upload = gallery_image_request(
            base_url,
            "folder_family",
            token=FIXTURE_TOKEN,
            idempotency_key="fixture-gallery-gif-0001",
            image=b"GIF89a",
            filename="new.gif",
            content_type="image/gif",
        )
        assert status == 415
        assert unsupported_upload["error"]["code"] == "unsupported_image"

        status, upload_retry = gallery_image_request(
            base_url,
            "folder_family",
            token=FIXTURE_TOKEN,
            idempotency_key=gallery_key,
        )
        assert status == 201
        assert upload_retry["image"]["id"] == uploaded["image"]["id"]

        status, upload_conflict = gallery_image_request(
            base_url,
            "folder_family",
            token=FIXTURE_TOKEN,
            idempotency_key=gallery_key,
            image=b"different-gallery-image",
        )
        assert status == 409
        assert upload_conflict["error"]["code"] == "idempotency_conflict"

        status, external_upload = gallery_image_request(
            base_url,
            "folder_nas_archive",
            token=FIXTURE_TOKEN,
            idempotency_key="fixture-gallery-external-01",
        )
        assert status == 409
        assert external_upload["error"]["code"] == "resource_conflict"

        image_content = urllib.request.Request(
            f"{base_url}{uploaded['image']['content_url']}",
            headers={
                "Authorization": f"Bearer {FIXTURE_TOKEN}",
                "If-None-Match": uploaded["image"]["etag"],
            },
        )
        try:
            urllib.request.urlopen(image_content, timeout=2)
            raise AssertionError("Expected a 304 response for Gallery content")
        except urllib.error.HTTPError as error:
            assert error.code == 304
            assert error.headers["ETag"] == uploaded["image"]["etag"]

        key = "fixture-test-key-0001"
        status, accepted = request(
            base_url,
            "/api/app/v1/dashboards/pantry/push",
            method="POST",
            payload={
                "device_ids": ["picpak-kitchen"],
                "override_quiet_hours": False,
            },
            token=FIXTURE_TOKEN,
            idempotency_key=key,
        )
        assert status == 202
        assert accepted["job"]["status"] == "accepted"

        status, retry = request(
            base_url,
            "/api/app/v1/dashboards/pantry/push",
            method="POST",
            payload={
                "device_ids": ["picpak-kitchen"],
                "override_quiet_hours": False,
            },
            token=FIXTURE_TOKEN,
            idempotency_key=key,
        )
        assert status == 202
        assert retry["job"]["id"] == accepted["job"]["id"]

        status, completed = request(
            base_url,
            f"/api/app/v1/jobs/{accepted['job']['id']}",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert completed["job"]["status"] == "succeeded"
        assert completed["job"]["result"]["status"] == "published"

        status, image_url = request(
            base_url,
            "/api/app/v1/image-urls",
            method="POST",
            payload={
                "url": "https://images.example.com/poster.png",
                "device_ids": ["picpak-kitchen"],
                "fit": "fill",
                "override_quiet_hours": False,
            },
            token=FIXTURE_TOKEN,
            idempotency_key="fixture-image-url-key-0001",
        )
        assert status == 202
        assert image_url["job"]["kind"] == "image_url_push"

        status, fetched_image_url = request(
            base_url,
            f"/api/app/v1/jobs/{image_url['job']['id']}",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert fetched_image_url["job"]["result"]["history_event_ids"]

        status, webpage = request(
            base_url,
            "/api/app/v1/webpages",
            method="POST",
            payload={
                "url": "https://example.com/news",
                "device_ids": ["picpak-kitchen", "e1004-desk"],
                "fit": "fit",
                "viewport_w": 1280,
                "override_quiet_hours": False,
            },
            token=FIXTURE_TOKEN,
            idempotency_key="fixture-webpage-key-0001",
        )
        assert status == 202
        assert webpage["job"]["kind"] == "webpage_push"
        assert webpage["job"]["target_device_ids"] == [
            "picpak-kitchen",
            "e1004-desk",
        ]

        status, rendered_webpage = request(
            base_url,
            f"/api/app/v1/jobs/{webpage['job']['id']}",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert rendered_webpage["job"]["result"]["history_event_ids"] == [
            "history_fixture_0003",
        ]

        status, blocked = request(
            base_url,
            "/api/app/v1/webpages",
            method="POST",
            payload={
                "url": "http://127.0.0.1:8765/admin",
                "device_ids": ["picpak-kitchen"],
                "fit": "fit",
                "override_quiet_hours": False,
            },
            token=FIXTURE_TOKEN,
            idempotency_key="fixture-webpage-key-0002",
        )
        assert status == 400
        assert blocked["error"]["code"] == "url_blocked"

        status, history = request(
            base_url,
            "/api/app/v1/history?limit=30",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert history["items"][0]["fit"] == "fill"
        assert history["items"][0]["framing"] == {
            "focus_x": 0.62,
            "focus_y": 0.38,
            "zoom": 1.35,
        }

        resend_key = "fixture-resend-key-0001"
        status, resend = request(
            base_url,
            "/api/app/v1/history/history_0102/resend",
            method="POST",
            payload={"override_quiet_hours": False},
            token=FIXTURE_TOKEN,
            idempotency_key=resend_key,
        )
        assert status == 202
        assert resend["job"]["kind"] == "history_resend"

        status, resent = request(
            base_url,
            f"/api/app/v1/jobs/{resend['job']['id']}",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert resent["job"]["result"]["history_event_ids"]

        preview = urllib.request.Request(
            f"{base_url}/api/app/v1/history/history_0102/preview",
            headers={
                "Accept": "image/png",
                "Authorization": f"Bearer {FIXTURE_TOKEN}",
            },
        )
        with urllib.request.urlopen(preview, timeout=2) as response:
            assert response.status == 200
            assert response.headers["Content-Type"] == "image/png"
            assert response.headers["ETag"] == '"history-preview-fixture"'
            assert response.read().startswith(b"\x89PNG")

        cached_preview = urllib.request.Request(
            f"{base_url}/api/app/v1/history/history_0102/preview",
            headers={
                "Accept": "image/png",
                "Authorization": f"Bearer {FIXTURE_TOKEN}",
                "If-None-Match": '"history-preview-fixture"',
            },
        )
        try:
            urllib.request.urlopen(cached_preview, timeout=2)
            raise AssertionError("Expected a 304 response for a matching ETag")
        except urllib.error.HTTPError as error:
            assert error.code == 304
            assert error.headers["ETag"] == '"history-preview-fixture"'

        status, framed_image = image_request(
            base_url,
            {
                "device_ids": ["picpak-kitchen", "e1004-desk"],
                "fit": "fill",
                "framing": {
                    "focus_x": 0.62,
                    "focus_y": 0.38,
                    "zoom": 1.35,
                },
                "override_quiet_hours": False,
            },
            token=FIXTURE_TOKEN,
            idempotency_key="fixture-framed-image-0001",
        )
        assert status == 202
        assert framed_image["job"]["kind"] == "image_push"
        assert framed_image["job"]["target_device_ids"] == [
            "picpak-kitchen",
            "e1004-desk",
        ]

        status, invalid_framing = image_request(
            base_url,
            {
                "device_ids": ["picpak-kitchen"],
                "fit": "blur",
                "framing": {
                    "focus_x": 0.5,
                    "focus_y": 0.5,
                    "zoom": 2,
                },
                "override_quiet_hours": False,
            },
            token=FIXTURE_TOKEN,
            idempotency_key="fixture-invalid-framing-01",
        )
        assert status == 400
        assert invalid_framing["error"]["code"] == "invalid_framing"

        status, excessive_zoom = image_request(
            base_url,
            {
                "device_ids": ["picpak-kitchen"],
                "fit": "fill",
                "framing": {
                    "focus_x": 0.5,
                    "focus_y": 0.5,
                    "zoom": framing_max_zoom + 0.01,
                },
                "override_quiet_hours": False,
            },
            token=FIXTURE_TOKEN,
            idempotency_key="fixture-framing-zoom-over-advertised-limit",
        )
        assert status == 400
        assert excessive_zoom["error"]["code"] == "invalid_framing"

        status, lineups = request(
            base_url,
            "/api/app/v1/lineups",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert lineups["lineups"][1]["native_editable"] is False
        assert lineups["lineups"][1]["dashboards"][0]["conditions"]

        status, lineup = request(
            base_url,
            "/api/app/v1/lineups/kitchen-deck",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert lineup["lineup"]["current"] == [
            {"device_id": "picpak-kitchen", "page_id": "pantry"}
        ]

        status, controlled = request(
            base_url,
            "/api/app/v1/lineups/kitchen-deck/actions",
            method="POST",
            payload={
                "action": "play",
                "page_id": "morning",
                "device_ids": ["picpak-kitchen"],
                "override_quiet_hours": False,
            },
            token=FIXTURE_TOKEN,
            idempotency_key="fixture-lineup-action-0001",
        )
        assert status == 202
        assert controlled["job"]["kind"] == "lineup_action"

        status, moved = request(
            base_url,
            "/api/app/v1/lineups/kitchen-deck",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert moved["lineup"]["current"] == [
            {"device_id": "picpak-kitchen", "page_id": "morning"}
        ]

        status, disabled = request(
            base_url,
            "/api/app/v1/lineups/kitchen-deck/actions",
            method="POST",
            payload={"action": "disable"},
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert disabled["lineup"]["enabled"] is False

        status, missing_key = request(
            base_url,
            "/api/app/v1/lineups/kitchen-deck/actions",
            method="POST",
            payload={"action": "next", "override_quiet_hours": False},
            token=FIXTURE_TOKEN,
        )
        assert status == 400
        assert missing_key["error"]["code"] == "invalid_request"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

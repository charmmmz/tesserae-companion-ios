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
        assert capabilities["limits"]["image_framing_max_zoom"] == 8
        assert "image_framing" in capabilities["features"]
        assert "history" in capabilities["features"]
        assert "image_url_push" in capabilities["features"]
        assert "webpage_push" in capabilities["features"]

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

        status, devices = request(
            base_url,
            "/api/app/v1/devices",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert devices["devices"][0]["id"] == "picpak-kitchen"

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
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

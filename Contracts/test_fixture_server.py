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
        assert "history" in capabilities["features"]

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

        status, history = request(
            base_url,
            "/api/app/v1/history?limit=30",
            token=FIXTURE_TOKEN,
        )
        assert status == 200
        assert history["items"][0]["fit"] == "blur"

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
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import jsonschema
import yaml


ROOT = Path(__file__).parent
SPEC = yaml.safe_load((ROOT / "app-v1.openapi.yaml").read_text())
FIXTURES = ROOT / "Fixtures"

CASES = {
    "capabilities.json": "Capabilities",
    "capabilities-previews.json": "Capabilities",
    "capabilities-extended.json": "Capabilities",
    "capabilities-framing.json": "Capabilities",
    "pair-request.json": "PairingRequest",
    "pair-response.json": "PairingResponse",
    "devices-response.json": "DevicesResponse",
    "dashboards-response.json": "DashboardsResponse",
    "dashboard-push-request.json": "DashboardPushRequest",
    "image-push-request.json": "ImagePushRequest",
    "image-push-request-basic.json": "ImagePushRequest",
    "image-url-push-request.json": "ImageURLPushRequest",
    "webpage-push-request.json": "WebpagePushRequest",
    "history-response.json": "HistoryResponse",
    "history-link-response.json": "HistoryResponse",
    "history-resend-request.json": "HistoryResendRequest",
    "job-accepted.json": "JobResponse",
    "job-published.json": "JobResponse",
    "job-quiet.json": "JobResponse",
    "job-failed.json": "JobResponse",
    "job-history-resend.json": "JobResponse",
    "job-image-url-published.json": "JobResponse",
    "job-webpage-published.json": "JobResponse",
    "job-webpage-blocked.json": "JobResponse",
    "error-response.json": "ErrorResponse",
}


def _pointer(ref: str) -> Any:
    assert ref.startswith("#/")
    value: Any = SPEC
    for part in ref[2:].split("/"):
        value = value[part.replace("~1", "/").replace("~0", "~")]
    return value


def _json_schema(value: Any) -> Any:
    if isinstance(value, list):
        return [_json_schema(item) for item in value]
    if not isinstance(value, dict):
        return value
    if "$ref" in value:
        resolved = _json_schema(_pointer(value["$ref"]))
        siblings = {key: item for key, item in value.items() if key != "$ref"}
        if siblings:
            return {"allOf": [resolved, _json_schema(siblings)]}
        return resolved

    converted = {
        key: _json_schema(item)
        for key, item in value.items()
        if key not in {"nullable", "discriminator", "example", "writeOnly", "readOnly"}
    }
    if value.get("nullable"):
        return {"anyOf": [converted, {"type": "null"}]}
    return converted


def test_openapi_shape_and_operation_ids_are_stable() -> None:
    assert SPEC["openapi"] == "3.0.3"
    assert SPEC["info"]["version"] == "0.6.0"
    assert set(SPEC["paths"]) == {
        "/api/app/v1",
        "/api/app/v1/pair",
        "/api/app/v1/session",
        "/api/app/v1/devices",
        "/api/app/v1/devices/{device_id}/preview",
        "/api/app/v1/dashboards",
        "/api/app/v1/dashboards/{dashboard_id}/preview",
        "/api/app/v1/dashboards/{dashboard_id}/push",
        "/api/app/v1/images",
        "/api/app/v1/image-urls",
        "/api/app/v1/webpages",
        "/api/app/v1/jobs/{job_id}",
        "/api/app/v1/history",
        "/api/app/v1/history/{history_id}/preview",
        "/api/app/v1/history/{history_id}/resend",
    }

    operation_ids = [
        operation["operationId"]
        for path in SPEC["paths"].values()
        for method, operation in path.items()
        if method in {"get", "post", "put", "patch", "delete"}
    ]
    assert len(operation_ids) == len(set(operation_ids))


def test_fixtures_match_component_schemas() -> None:
    for fixture_name, schema_name in CASES.items():
        fixture = json.loads((FIXTURES / fixture_name).read_text())
        schema = _json_schema(SPEC["components"]["schemas"][schema_name])
        jsonschema.validate(
            fixture,
            schema,
            format_checker=jsonschema.FormatChecker(),
        )


def test_job_lifecycle_and_business_outcome_are_separate() -> None:
    accepted = json.loads((FIXTURES / "job-accepted.json").read_text())["job"]
    published = json.loads((FIXTURES / "job-published.json").read_text())["job"]
    quiet = json.loads((FIXTURES / "job-quiet.json").read_text())["job"]
    failed = json.loads((FIXTURES / "job-failed.json").read_text())["job"]

    assert accepted["status"] == "accepted"
    assert accepted["result"] is None
    assert published["status"] == "succeeded"
    assert published["result"]["status"] == "published"
    assert quiet["status"] == "succeeded"
    assert quiet["result"]["status"] == "quiet"
    assert failed["status"] == "failed"
    assert failed["error"]["code"]


def test_all_write_operations_require_idempotency_key() -> None:
    paths = SPEC["paths"]
    write_operations = [
        paths["/api/app/v1/dashboards/{dashboard_id}/push"]["post"],
        paths["/api/app/v1/images"]["post"],
        paths["/api/app/v1/image-urls"]["post"],
        paths["/api/app/v1/webpages"]["post"],
        paths["/api/app/v1/history/{history_id}/resend"]["post"],
    ]
    for operation in write_operations:
        refs = [parameter.get("$ref") for parameter in operation["parameters"]]
        assert "#/components/parameters/IdempotencyKey" in refs


def test_preview_endpoints_are_read_only_and_conditional() -> None:
    paths = SPEC["paths"]
    device = paths["/api/app/v1/devices/{device_id}/preview"]
    dashboard = paths["/api/app/v1/dashboards/{dashboard_id}/preview"]
    history = paths["/api/app/v1/history/{history_id}/preview"]

    assert set(device) == {"parameters", "get"}
    assert set(dashboard) == {"parameters", "get"}
    assert set(history) == {"parameters", "get"}
    assert set(device["get"]["responses"]) == {"200", "304", "401", "404"}
    assert set(dashboard["get"]["responses"]) == {
        "200",
        "202",
        "304",
        "400",
        "401",
        "404",
    }
    assert set(history["get"]["responses"]) == {"200", "304", "401", "404"}
    features = SPEC["components"]["schemas"]["Capabilities"]["properties"][
        "features"
    ]["items"]["enum"]
    assert "previews" in features

    base = json.loads((FIXTURES / "capabilities.json").read_text())
    extension = json.loads(
        (FIXTURES / "capabilities-previews.json").read_text()
    )
    assert "previews" not in base["features"]
    assert "previews" in extension["features"]


def test_pending_render_identifies_an_exact_preview_revision() -> None:
    device = json.loads(
        (FIXTURES / "devices-response.json").read_text()
    )["devices"][0]
    assert device["pending_render"] == {
        "revision": "a1b2c3d4e5f67890",
        "rendered_at": "2026-07-28T08:00:00Z",
        "preview_url": (
            "/api/app/v1/devices/picpak-kitchen/preview"
            "?revision=a1b2c3d4e5f67890"
        ),
    }

    parameters = SPEC["paths"][
        "/api/app/v1/devices/{device_id}/preview"
    ]["get"]["parameters"]
    revision = next(item for item in parameters if item.get("name") == "revision")
    assert revision["in"] == "query"
    assert revision["required"] is False


def test_extended_capabilities_advertise_history_and_all_image_fit_modes() -> None:
    base = json.loads((FIXTURES / "capabilities.json").read_text())
    extension = json.loads((FIXTURES / "capabilities-extended.json").read_text())

    assert "image_fit_modes" not in base["limits"]
    assert extension["limits"]["image_fit_modes"] == [
        "fit",
        "fill",
        "blur",
        "stretch",
        "center",
    ]
    assert "history" in extension["features"]
    assert "image_url_push" in extension["features"]
    assert "webpage_push" in extension["features"]
    assert SPEC["components"]["schemas"]["ImageFitMode"]["enum"] == [
        "fit",
        "fill",
        "blur",
        "stretch",
        "center",
    ]


def test_image_framing_is_independently_gated_and_fill_only() -> None:
    base = json.loads((FIXTURES / "capabilities-extended.json").read_text())
    framing_capabilities = json.loads(
        (FIXTURES / "capabilities-framing.json").read_text()
    )
    basic = json.loads(
        (FIXTURES / "image-push-request-basic.json").read_text()
    )
    framed = json.loads((FIXTURES / "image-push-request.json").read_text())

    assert "image_framing" not in base["features"]
    assert "image_framing_max_zoom" not in base["limits"]
    assert "image_framing" in framing_capabilities["features"]
    assert framing_capabilities["limits"]["image_framing_max_zoom"] == 8

    assert "framing" not in basic
    assert framed["fit"] == "fill"
    assert framed["framing"] == {
        "focus_x": 0.62,
        "focus_y": 0.38,
        "zoom": 1.35,
    }

    request = SPEC["components"]["schemas"]["ImagePushRequest"]
    description = request["properties"]["framing"]["description"]
    assert "fit=fill" in description
    assert "resolved independently" in description
    assert "centered Fill" in description

    schema = SPEC["components"]["schemas"]["ImageFraming"]
    assert schema["required"] == ["focus_x", "focus_y", "zoom"]
    assert schema["properties"]["focus_x"]["minimum"] == 0
    assert schema["properties"]["focus_x"]["maximum"] == 1
    assert schema["properties"]["focus_y"]["minimum"] == 0
    assert schema["properties"]["focus_y"]["maximum"] == 1
    assert schema["properties"]["zoom"]["minimum"] == 1


def test_link_push_contract_keeps_routes_and_failures_distinct() -> None:
    paths = SPEC["paths"]
    image_url = paths["/api/app/v1/image-urls"]["post"]
    webpage = paths["/api/app/v1/webpages"]["post"]

    assert image_url["requestBody"]["content"]["application/json"]["schema"] == {
        "$ref": "#/components/schemas/ImageURLPushRequest"
    }
    assert webpage["requestBody"]["content"]["application/json"]["schema"] == {
        "$ref": "#/components/schemas/WebpagePushRequest"
    }
    assert image_url["operationId"] != webpage["operationId"]
    assert "strict Companion URL policy" in image_url["description"]
    assert "manual Server preview" in webpage["description"]

    kinds = SPEC["components"]["schemas"]["Job"]["properties"]["kind"]["enum"]
    assert "image_url_push" in kinds
    assert "webpage_push" in kinds


def test_webpage_uses_one_bounded_logical_viewport_render() -> None:
    request = SPEC["components"]["schemas"]["WebpagePushRequest"]
    viewport = request["properties"]["viewport_w"]

    assert "viewport_w" not in request["required"]
    assert viewport == {
        "description": (
            "Optional advanced logical browser width. The server defaults to "
            "1280 and owns the logical capture height. It renders once at that "
            "logical size and does not re-render for each target display."
        ),
        "type": "integer",
        "minimum": 200,
        "maximum": 4096,
        "default": 1280,
    }


def test_link_sources_use_strict_public_network_policy() -> None:
    remote_url = SPEC["components"]["schemas"]["RemoteSourceURL"]

    assert remote_url["pattern"] == r"^https?://[^\s]+$"
    assert remote_url["format"] == "uri"
    for refused in ("private", "loopback", "link-local"):
        assert refused in remote_url["description"]
    assert "cannot override" in remote_url["description"]


def test_link_history_identifies_source_compositions() -> None:
    history = json.loads((FIXTURES / "history-link-response.json").read_text())
    webpage, image_url = history["items"]

    assert webpage["source"] == "webpage"
    assert webpage["preview_available"] is True
    assert webpage["resendable"] is True
    assert image_url["source"] == "url"
    assert image_url["fit"] == "fill"

    image_job = json.loads(
        (FIXTURES / "job-image-url-published.json").read_text()
    )["job"]
    webpage_job = json.loads(
        (FIXTURES / "job-webpage-published.json").read_text()
    )["job"]
    blocked_job = json.loads(
        (FIXTURES / "job-webpage-blocked.json").read_text()
    )["job"]

    assert image_job["result"]["history_event_ids"]
    assert webpage_job["result"]["history_event_ids"]
    assert blocked_job["status"] == "failed"
    assert blocked_job["error"]["code"] == "url_blocked"


def test_history_contract_keeps_composition_preview_and_resend_correlatable() -> None:
    history = json.loads((FIXTURES / "history-response.json").read_text())
    photo = history["items"][0]
    resend = json.loads((FIXTURES / "job-history-resend.json").read_text())["job"]

    assert photo["preview_available"] is True
    assert photo["fit"] == "fill"
    assert photo["framing"] == {
        "focus_x": 0.62,
        "focus_y": 0.38,
        "zoom": 1.35,
    }
    assert resend["kind"] == "history_resend"
    assert resend["result"]["history_event_ids"]

    preview_description = SPEC["paths"][
        "/api/app/v1/history/{history_id}/preview"
    ]["get"]["responses"]["200"]["description"]
    assert "not a device-final preview" in preview_description

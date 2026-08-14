from __future__ import annotations

import base64
import json
from pathlib import Path
from typing import Any

import jsonschema
import pytest
import yaml


ROOT = Path(__file__).parent
SPEC = yaml.safe_load((ROOT / "app-v1.openapi.yaml").read_text())
FIXTURES = ROOT / "Fixtures"

CASES = {
    "capabilities.json": "Capabilities",
    "capabilities-previews.json": "Capabilities",
    "capabilities-extended.json": "Capabilities",
    "capabilities-framing.json": "Capabilities",
    "capabilities-lineups.json": "Capabilities",
    "capabilities-lineup-authoring.json": "Capabilities",
    "capabilities-gallery.json": "Capabilities",
    "pair-request.json": "PairingRequest",
    "pair-response.json": "PairingResponse",
    "pair-response-lineups.json": "PairingResponse",
    "pair-response-gallery.json": "PairingResponse",
    "session-authorization.json": "CompanionSessionAuthorization",
    "devices-response.json": "DevicesResponse",
    "devices-gallery-response.json": "DevicesResponse",
    "dashboards-response.json": "DashboardsResponse",
    "dashboard-push-request.json": "DashboardPushRequest",
    "image-push-request.json": "ImagePushRequest",
    "image-push-request-basic.json": "ImagePushRequest",
    "gallery-folders-response.json": "GalleryFoldersResponse",
    "gallery-folder-response.json": "GalleryFolderResponse",
    "gallery-external-folder-response.json": "GalleryFolderResponse",
    "gallery-folder-create-request.json": "GalleryFolderCreateRequest",
    "gallery-image-upload-response.json": "GalleryImageResponse",
    "image-url-push-request.json": "ImageURLPushRequest",
    "webpage-push-request.json": "WebpagePushRequest",
    "history-response.json": "HistoryResponse",
    "history-link-response.json": "HistoryResponse",
    "history-resend-request.json": "HistoryResendRequest",
    "lineups-response.json": "LineupsResponse",
    "lineup-response.json": "LineupResponse",
    "lineup-daily-resolved-response.json": "LineupResponse",
    "lineup-create-request.json": "LineupCreateRequest",
    "lineup-patch-request.json": "LineupPatchRequest",
    "lineup-action-request.json": "LineupActionRequest",
    "lineup-state-action-request.json": "LineupActionRequest",
    "job-accepted.json": "JobResponse",
    "job-published.json": "JobResponse",
    "job-quiet.json": "JobResponse",
    "job-failed.json": "JobResponse",
    "job-history-resend.json": "JobResponse",
    "job-image-url-published.json": "JobResponse",
    "job-webpage-published.json": "JobResponse",
    "job-webpage-blocked.json": "JobResponse",
    "job-lineup-action.json": "JobResponse",
    "error-response.json": "ErrorResponse",
    "error-forbidden.json": "ErrorResponse",
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
    assert SPEC["info"]["version"] == "0.11.0"
    assert set(SPEC["paths"]) == {
        "/api/app/v1",
        "/api/app/v1/pair",
        "/api/app/v1/session",
        "/api/app/v1/personal-data/status",
        "/api/app/v1/personal-data/{source_id}",
        "/api/app/v1/devices",
        "/api/app/v1/devices/{device_id}/preview",
        "/api/app/v1/dashboards",
        "/api/app/v1/dashboards/{dashboard_id}/preview",
        "/api/app/v1/dashboards/{dashboard_id}/push",
        "/api/app/v1/images",
        "/api/app/v1/gallery/folders",
        "/api/app/v1/gallery/folders/{folder_id}",
        "/api/app/v1/gallery/folders/{folder_id}/images",
        "/api/app/v1/gallery/images/{image_id}/thumbnail",
        "/api/app/v1/gallery/images/{image_id}/content",
        "/api/app/v1/image-urls",
        "/api/app/v1/webpages",
        "/api/app/v1/lineups",
        "/api/app/v1/lineups/{lineup_id}",
        "/api/app/v1/lineups/{lineup_id}/actions",
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


def test_all_unconditional_job_writes_require_idempotency_key() -> None:
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


def test_lineup_read_is_lossless_and_action_response_matches_effect() -> None:
    fixture = json.loads((FIXTURES / "lineups-response.json").read_text())
    detail = json.loads((FIXTURES / "lineup-response.json").read_text())["lineup"]
    advanced = fixture["lineups"][1]

    assert all(
        lineup["web_url"] == f"/decks/{lineup['id']}/edit"
        for lineup in fixture["lineups"]
    )
    assert detail["web_url"] == f"/decks/{detail['id']}/edit"
    assert advanced["native_editable"] is False
    assert advanced["requires_web_reason"]
    assert advanced["dashboards"][0]["conditions"]
    assert advanced["mode"] == "priority"
    assert advanced["smart_sync"] is True
    assert advanced["current"] == [
        {"device_id": "picpak-kitchen", "page_id": "photo-frame"},
        {"device_id": "e1004-desk", "page_id": "morning"},
    ]
    assert "legacy_kind" not in advanced

    schemas = SPEC["components"]["schemas"]
    required = set(schemas["Lineup"]["required"])
    assert {
        "dashboards",
        "current",
        "trigger",
        "smart_sync",
        "fallback_page_id",
        "native_editable",
        "requires_web_reason",
    } <= required
    assert set(schemas["Lineup"]["properties"]) == required
    assert set(schemas["Lineup"]["properties"]["intent"]["enum"]) == {
        "daily",
        "interval",
        "cycle",
        "manual",
    }

    paths = SPEC["paths"]
    operation = paths["/api/app/v1/lineups/{lineup_id}/actions"]["post"]
    parameter_refs = [item.get("$ref") for item in operation["parameters"]]
    assert "#/components/parameters/ConditionalIdempotencyKey" in parameter_refs
    assert operation["responses"]["200"]["content"]["application/json"][
        "schema"
    ] == {"$ref": "#/components/schemas/LineupResponse"}
    assert operation["responses"]["202"] == {
        "$ref": "#/components/responses/JobAccepted"
    }

    state_actions = schemas["LineupStateActionRequest"]["properties"]["action"]["enum"]
    paint_actions = schemas["LineupPaintActionRequest"]["properties"]["action"]["enum"]
    assert set(state_actions) == {"enable", "disable"}
    assert set(paint_actions) == {"next", "previous", "play"}

    scopes = schemas["PairingResponse"]["properties"]["scopes"]["items"]["enum"]
    assert "lineups:read" in scopes
    assert "lineups:control" in scopes
    assert "lineups:write" not in scopes


def test_preview_endpoints_are_read_only_and_conditional() -> None:
    paths = SPEC["paths"]
    device = paths["/api/app/v1/devices/{device_id}/preview"]
    dashboard = paths["/api/app/v1/dashboards/{dashboard_id}/preview"]
    history = paths["/api/app/v1/history/{history_id}/preview"]

    assert set(device) == {"parameters", "get"}
    assert set(dashboard) == {"parameters", "get"}
    assert set(history) == {"parameters", "get"}
    assert set(device["get"]["responses"]) == {"200", "304", "401", "403", "404"}
    assert set(dashboard["get"]["responses"]) == {
        "200",
        "202",
        "304",
        "400",
        "401",
        "403",
        "404",
    }
    assert set(history["get"]["responses"]) == {"200", "304", "401", "403", "404"}
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


def test_scoped_routes_distinguish_invalid_credentials_from_missing_scopes() -> None:
    forbidden_ref = {"$ref": "#/components/responses/Forbidden"}
    scoped_operations = []
    for path, path_item in SPEC["paths"].items():
        for method, operation in path_item.items():
            if method not in {"get", "post", "put", "patch", "delete"}:
                continue
            responses = operation.get("responses", {})
            if "401" in responses and path != "/api/app/v1/session":
                scoped_operations.append((path, method))
                assert responses.get("403") == forbidden_ref

    assert scoped_operations
    assert "forbidden" in SPEC["components"]["schemas"]["ErrorResponse"][
        "properties"
    ]["error"]["properties"]["code"]["enum"]
    assert "403" not in SPEC["paths"]["/api/app/v1/session"]["delete"]["responses"]


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
    assert framing_capabilities["limits"]["image_framing_max_zoom"] == 4

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

    error_codes = SPEC["components"]["schemas"]["ErrorResponse"]["properties"][
        "error"
    ]["properties"]["code"]["enum"]
    assert "invalid_framing" in error_codes


def test_image_framing_uses_orientation_normalized_source_space() -> None:
    fixture = json.loads(
        (FIXTURES / "image-framing-exif-rotate-90.json").read_text()
    )
    image = base64.b64decode(fixture["jpeg_base64"], validate=True)
    raw = fixture["raw_source"]
    normalized = fixture["normalized_source"]
    target = fixture["target"]

    assert image.startswith(b"\xff\xd8")
    assert image.endswith(b"\xff\xd9")
    assert raw == {"width": 40, "height": 30, "exif_orientation": 6}
    assert normalized == {"width": 30, "height": 40, "exif_orientation": 1}

    def resolve(
        source: dict[str, int],
        framing: dict[str, float],
    ) -> dict[str, float]:
        source_aspect = source["width"] / source["height"]
        target_aspect = target["width"] / target["height"]
        if source_aspect >= target_aspect:
            base_width = target_aspect / source_aspect
            base_height = 1.0
        else:
            base_width = 1.0
            base_height = source_aspect / target_aspect
        width = base_width / framing["zoom"]
        height = base_height / framing["zoom"]
        return {
            "x": min(
                max(framing["focus_x"] - width / 2, 0),
                1 - width,
            ),
            "y": min(
                max(framing["focus_y"] - height / 2, 0),
                1 - height,
            ),
            "width": width,
            "height": height,
        }

    framing = fixture["framing"]
    resolved = resolve(normalized, framing)
    for key, expected in fixture["expected_crop"].items():
        assert resolved[key] == pytest.approx(expected)
    assert resolve(raw, framing)["x"] != pytest.approx(resolved["x"])

    clamp_case = fixture["clamp_case"]
    clamp_framing = clamp_case["framing"]
    clamped = resolve(normalized, clamp_framing)
    for key, expected in clamp_case["expected_crop"].items():
        assert clamped[key] == pytest.approx(expected)
    assert clamp_framing["focus_x"] - clamped["width"] / 2 > 1 - clamped[
        "width"
    ]
    assert clamp_framing["focus_y"] - clamped["height"] / 2 < 0
    assert clamped["x"] == pytest.approx(1 - clamped["width"])
    assert clamped["y"] == pytest.approx(0)

    schema = SPEC["components"]["schemas"]["ImageFraming"]
    assert "applies EXIF orientation" in schema["description"]
    assert "orientation-normalized" in schema["properties"]["focus_x"][
        "description"
    ]


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


def test_gallery_contract_is_capability_gated_and_non_destructive() -> None:
    base = json.loads((FIXTURES / "capabilities.json").read_text())
    gallery = json.loads((FIXTURES / "capabilities-gallery.json").read_text())

    assert "gallery" not in base["features"]
    assert "gallery" in gallery["features"]
    assert gallery["limits"]["gallery_upload_bytes"] == 20 * 1024 * 1024
    assert gallery["limits"]["gallery_upload_batch_size"] == 20
    assert gallery["limits"]["gallery_image_content_types"] == [
        "image/jpeg",
        "image/png",
        "image/heic",
        "image/heif",
        "image/webp",
    ]

    pairing_scopes = SPEC["components"]["schemas"]["PairingResponse"][
        "properties"
    ]["scopes"]["items"]["enum"]
    session_scopes = SPEC["components"]["schemas"][
        "CompanionSessionAuthorization"
    ]["properties"]["scopes"]["items"]["enum"]
    assert "gallery:read" in pairing_scopes
    assert "gallery:write" in pairing_scopes
    assert "gallery:read" in session_scopes
    assert "gallery:write" in session_scopes
    assert "gallery:manage" not in pairing_scopes
    assert "gallery:manage" not in session_scopes

    folder_resource = SPEC["paths"][
        "/api/app/v1/gallery/folders/{folder_id}"
    ]
    assert set(folder_resource).isdisjoint({"delete", "patch", "put"})
    assert not any(
        "delete" in path or "move" in path or "rename" in path
        for path in SPEC["paths"]
        if path.startswith("/api/app/v1/gallery/")
    )

    folders = json.loads((FIXTURES / "gallery-folders-response.json").read_text())
    external = next(folder for folder in folders["folders"] if folder["kind"] == "external")
    assert external["writable"] is False
    assert "external_path" not in external


def test_gallery_upload_is_one_synchronous_idempotent_image() -> None:
    operation = SPEC["paths"][
        "/api/app/v1/gallery/folders/{folder_id}/images"
    ]["post"]
    parameter_refs = [item.get("$ref") for item in operation["parameters"]]
    assert "#/components/parameters/IdempotencyKey" in parameter_refs

    form = operation["requestBody"]["content"]["multipart/form-data"]["schema"]
    assert form["required"] == ["image"]
    assert set(form["properties"]) == {"image"}
    assert form["properties"]["image"]["format"] == "binary"
    assert operation["responses"]["201"]["content"]["application/json"][
        "schema"
    ] == {"$ref": "#/components/schemas/GalleryImageResponse"}
    assert operation["responses"]["201"] != {
        "$ref": "#/components/responses/JobAccepted"
    }

    description = operation["description"]
    assert "exactly one image" in description
    assert "removes all location metadata" in description
    assert "bakes orientation" in description
    assert "preserves the ICC colour profile" in description
    assert "neither a Job nor History" in description

    error_codes = SPEC["components"]["schemas"]["ErrorResponse"]["properties"][
        "error"
    ]["properties"]["code"]["enum"]
    assert "resource_conflict" in error_codes


def test_device_capability_support_is_runtime_computed_and_tri_state() -> None:
    response = json.loads(
        (FIXTURES / "devices-gallery-response.json").read_text()
    )
    by_id = {device["id"]: device for device in response["devices"]}

    assert by_id["picpak-kitchen"]["capability_support"]["frame_cache"] == {
        "state": "unsupported",
        "reason_code": "not_advertised",
        "observed_at": "2026-08-14T07:58:30Z",
    }
    assert by_id["e1004-desk"]["capability_support"]["frame_cache"][
        "state"
    ] == "supported"
    assert by_id["e1003-bedroom"]["capability_support"]["frame_cache"] == {
        "state": "unknown",
        "reason_code": "no_usable_heartbeat",
        "observed_at": None,
    }

    field_description = SPEC["components"]["schemas"]["Device"]["properties"][
        "capability_support"
    ]["description"]
    assert "rather than device model" in field_description
    assert "must not infer support from an SD-card model list" in field_description

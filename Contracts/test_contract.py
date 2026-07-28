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
    "pair-request.json": "PairingRequest",
    "pair-response.json": "PairingResponse",
    "devices-response.json": "DevicesResponse",
    "dashboards-response.json": "DashboardsResponse",
    "dashboard-push-request.json": "DashboardPushRequest",
    "image-push-request.json": "ImagePushRequest",
    "job-accepted.json": "JobResponse",
    "job-published.json": "JobResponse",
    "job-quiet.json": "JobResponse",
    "job-failed.json": "JobResponse",
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
    assert SPEC["info"]["version"] == "0.3.0"
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
        "/api/app/v1/jobs/{job_id}",
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


def test_both_write_operations_require_idempotency_key() -> None:
    paths = SPEC["paths"]
    write_operations = [
        paths["/api/app/v1/dashboards/{dashboard_id}/push"]["post"],
        paths["/api/app/v1/images"]["post"],
    ]
    for operation in write_operations:
        refs = [parameter.get("$ref") for parameter in operation["parameters"]]
        assert "#/components/parameters/IdempotencyKey" in refs


def test_preview_endpoints_are_read_only_and_conditional() -> None:
    paths = SPEC["paths"]
    device = paths["/api/app/v1/devices/{device_id}/preview"]
    dashboard = paths["/api/app/v1/dashboards/{dashboard_id}/preview"]

    assert set(device) == {"parameters", "get"}
    assert set(dashboard) == {"parameters", "get"}
    assert set(device["get"]["responses"]) == {"200", "304", "401", "404"}
    assert set(dashboard["get"]["responses"]) == {
        "200",
        "202",
        "304",
        "400",
        "401",
        "404",
    }
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

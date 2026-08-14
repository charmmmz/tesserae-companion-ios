from __future__ import annotations

import json
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import jsonschema
import pytest
import yaml


ROOT = Path(__file__).parent
FIXTURES = ROOT / "Fixtures"
SPEC = yaml.safe_load((ROOT / "app-v1.openapi.yaml").read_text())


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


def load_fixture(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / name).read_text())


def validate_fixture(name: str, schema_name: str) -> None:
    jsonschema.validate(
        load_fixture(name),
        _json_schema(SPEC["components"]["schemas"][schema_name]),
        format_checker=jsonschema.FormatChecker(),
    )


def test_personal_data_fixtures_match_strict_schemas() -> None:
    validate_fixture("capabilities-personal-data.json", "Capabilities")
    validate_fixture("pair-response-personal-data.json", "PairingResponse")
    validate_fixture("personal-data-reminders-fridge.json", "PersonalDataSnapshot")
    validate_fixture("personal-data-reminders.json", "PersonalDataSnapshot")
    validate_fixture("personal-data-reminders-empty.json", "PersonalDataSnapshot")
    validate_fixture("personal-data-health-summary.json", "PersonalDataSnapshot")
    validate_fixture("personal-data-health-summary-partial.json", "PersonalDataSnapshot")
    validate_fixture(
        "personal-data-health-summary-put-response.json",
        "PersonalDataSourceStatus",
    )
    validate_fixture("personal-data-put-response.json", "PersonalDataSourceStatus")
    validate_fixture("personal-data-status.json", "PersonalDataStatusResponse")


def test_reminders_snapshot_is_minimal_and_expiring() -> None:
    snapshot = load_fixture("personal-data-reminders-fridge.json")
    generated_at = datetime.fromisoformat(snapshot["generated_at"].replace("Z", "+00:00"))
    expires_at = datetime.fromisoformat(snapshot["expires_at"].replace("Z", "+00:00"))

    assert snapshot["version"] == "personal_data_bridge_v1"
    assert snapshot["source_id"] == "reminders.fridge"
    assert expires_at > generated_at
    assert set(snapshot["data"]) == {"items"}
    assert all(
        set(item) == {"id", "title", "due_date", "priority", "completed"}
        for item in snapshot["data"]["items"]
    )
    assert all(item["completed"] is False for item in snapshot["data"]["items"])


def test_empty_reminders_snapshot_keeps_the_source_enabled() -> None:
    snapshot = load_fixture("personal-data-reminders-empty.json")

    assert snapshot["source_id"] == "reminders"
    assert snapshot["data"] == {"lists": []}
    validate_fixture("personal-data-reminders-empty.json", "PersonalDataSnapshot")


def test_personal_data_routes_are_one_family_and_not_render_triggers() -> None:
    paths = SPEC["paths"]
    resource = paths["/api/app/v1/personal-data/{source_id}"]
    status = paths["/api/app/v1/personal-data/status"]

    assert set(resource) == {"parameters", "put", "delete"}
    assert set(status) == {"get"}
    assert resource["put"]["responses"]["200"]["content"]["application/json"][
        "schema"
    ]["$ref"] == "#/components/schemas/PersonalDataSourceStatus"
    assert "IdempotencyKey" not in json.dumps(resource["put"].get("parameters", []))
    assert "render" not in resource["put"]["summary"].lower()
    assert "push" not in resource["put"]["summary"].lower()
    assert resource["delete"]["responses"]["204"]["description"]


def test_personal_data_is_independently_capability_and_scope_gated() -> None:
    base = load_fixture("capabilities.json")
    extension = load_fixture("capabilities-personal-data.json")
    pairing = load_fixture("pair-response-personal-data.json")

    assert "personal_data_reminders" not in base["features"]
    assert "personal_data_reminders" in extension["features"]
    assert "personal_data_health" in extension["features"]
    assert extension["personal_data"]["sources"] == [
        "reminders",
        "reminders.fridge",
        "health.summary",
    ]
    assert "personal_data_reminders_multi_list" not in extension["features"]
    assert extension["limits"]["personal_data_stale_after_seconds"] == 86_400
    assert extension["limits"]["personal_data_max_ttl_seconds"] == 172_800
    assert "personal_data:write" in pairing["scopes"]
    assert "personal_data:write" in SPEC["components"]["schemas"]["PairingResponse"][
        "properties"
    ]["scopes"]["items"]["enum"]


def test_health_summary_is_a_bounded_seven_date_snapshot() -> None:
    snapshot = load_fixture("personal-data-health-summary.json")
    data = snapshot["data"]
    generated_at = datetime.fromisoformat(snapshot["generated_at"].replace("Z", "+00:00"))
    expires_at = datetime.fromisoformat(snapshot["expires_at"].replace("Z", "+00:00"))
    start = date.fromisoformat(data["window_start_date"])
    end = date.fromisoformat(data["window_end_date"])

    assert snapshot["version"] == "personal_data_bridge_v1"
    assert snapshot["source_id"] == "health.summary"
    assert expires_at - generated_at == timedelta(hours=48)
    assert end - start == timedelta(days=6)
    assert set(data) == {
        "time_zone",
        "window_start_date",
        "window_end_date",
        "activity",
        "sleep",
        "workouts",
    }

    days = data["activity"]["days"]
    assert [date.fromisoformat(day["date"]) for day in days] == [
        start + timedelta(days=offset) for offset in range(7)
    ]
    for day in days:
        if day["move_mode"] == "active_energy":
            assert day["move_minutes"] is None
            assert day["move_goal_minutes"] is None
        elif day["move_mode"] == "move_time":
            assert day["active_energy_kcal"] is None
            assert day["active_energy_goal_kcal"] is None


def test_health_sleep_uses_wake_date_without_raw_samples() -> None:
    snapshot = load_fixture("personal-data-health-summary.json")
    data = snapshot["data"]
    zone = ZoneInfo(data["time_zone"])
    nights = data["sleep"]["nights"]

    assert len({night["wake_date"] for night in nights}) == len(nights)
    for night in nights:
        end_at = datetime.fromisoformat(night["end_at"].replace("Z", "+00:00"))
        assert night["wake_date"] == end_at.astimezone(zone).date().isoformat()
        assert datetime.fromisoformat(night["start_at"].replace("Z", "+00:00")) < end_at
        assert not ({"samples", "source", "device", "uuid"} & set(night))


def test_health_workouts_keep_stable_opaque_shape_and_explicit_metrics() -> None:
    snapshot = load_fixture("personal-data-health-summary.json")
    workouts = snapshot["data"]["workouts"]["items"]
    expected_metrics = {
        "active_energy_kcal",
        "walking_running_distance_meters",
        "cycling_distance_meters",
        "swimming_distance_meters",
        "wheelchair_distance_meters",
        "flights_climbed",
        "swimming_stroke_count",
    }

    assert len({workout["id"] for workout in workouts}) == len(workouts)
    assert sum(len(workout["segments"]) for workout in workouts) <= 256
    for workout in workouts:
        assert len(workout["id"]) == 24
        assert set(workout) >= expected_metrics
        assert not (
            {"uuid", "route", "location", "heart_rate", "events", "metadata"}
            & set(workout)
        )
        assert datetime.fromisoformat(
            workout["start_at"].replace("Z", "+00:00")
        ) < datetime.fromisoformat(workout["end_at"].replace("Z", "+00:00"))
        assert [segment["ordinal"] for segment in workout["segments"]] == list(
            range(len(workout["segments"]))
        )


def test_health_optional_sections_are_explicit_and_not_all_null() -> None:
    partial = load_fixture("personal-data-health-summary-partial.json")
    data = partial["data"]

    assert data["activity"] is None
    assert data["sleep"] == {"nights": []}
    assert data["workouts"] is None

    all_null = json.loads(json.dumps(partial))
    all_null["data"]["sleep"] = None
    schema = _json_schema(SPEC["components"]["schemas"]["PersonalDataSnapshot"])
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(
            all_null,
            schema,
            format_checker=jsonschema.FormatChecker(),
        )


def test_status_metadata_cannot_carry_snapshot_values() -> None:
    status_schema = SPEC["components"]["schemas"]["PersonalDataSourceStatus"]
    assert set(status_schema["properties"]) == {
        "source_id",
        "state",
        "generated_at",
        "stale_at",
        "expires_at",
    }
    assert status_schema["additionalProperties"] is False
    assert "data" not in status_schema["properties"]

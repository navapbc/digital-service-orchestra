from __future__ import annotations

import json
from pathlib import Path

import pytest
import jsonschema

REPO_ROOT = Path(__file__).parent.parent.parent
SCHEMA_PATH = REPO_ROOT / "plugins/dso/docs/visual-evaluator-schema.json"
FIXTURES_DIR = Path(__file__).parent / "fixtures" / "visual-evaluator"


@pytest.fixture
def schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text())


def test_conformant_fixture_validates(schema: dict) -> None:
    """Conformant fixture passes schema validation without error."""
    fixture = json.loads((FIXTURES_DIR / "conformant-fixture.json").read_text())
    jsonschema.validate(instance=fixture, schema=schema)


@pytest.mark.parametrize(
    "filename",
    [
        "malformed-fixture-missing-dom-xpath.json",
        "malformed-fixture-wrong-type.json",
        "malformed-fixture-bad-enum.json",
        "malformed-fixture-score-out-of-range.json",
        "malformed-fixture-extra-field.json",
    ],
)
def test_malformed_fixture_rejected(schema: dict, filename: str) -> None:
    """Each malformed fixture raises jsonschema.ValidationError."""
    fixture = json.loads((FIXTURES_DIR / filename).read_text())
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=fixture, schema=schema)


def test_schema_has_required_top_level_fields(schema: dict) -> None:
    required = set(schema.get("required", []))
    assert {
        "scores",
        "findings",
        "attribution_class",
        "attribution_confidence",
    }.issubset(required)


def test_schema_scores_five_integer_dimensions(schema: dict) -> None:
    score_props = schema["properties"]["scores"]["properties"]
    assert len(score_props) == 5
    for dim, spec in score_props.items():
        assert spec["type"] == "integer"
        assert spec["minimum"] == 1
        assert spec["maximum"] == 5


def test_schema_bbox_confidence_enum(schema: dict) -> None:
    finding_props = schema["properties"]["findings"]["items"]["properties"]
    assert set(finding_props["bbox_confidence"]["enum"]) == {"anchored", "inferred"}

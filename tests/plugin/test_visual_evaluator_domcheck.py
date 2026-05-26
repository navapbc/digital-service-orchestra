from __future__ import annotations

import json
from pathlib import Path

import jsonschema
import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
SCHEMA_PATH = REPO_ROOT / "plugins/dso/docs/visual-evaluator-schema.json"
FIXTURES_DIR = Path(__file__).parent / "fixtures" / "visual-evaluator"
MISMATCH_FIXTURE = FIXTURES_DIR / "mismatch-fixture-expected.json"
CONSISTENT_FIXTURE = FIXTURES_DIR / "consistent-fixture-expected.json"


@pytest.fixture
def schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text())


@pytest.fixture
def mismatch_output() -> dict:
    return json.loads(MISMATCH_FIXTURE.read_text())


@pytest.fixture
def consistent_output() -> dict:
    return json.loads(CONSISTENT_FIXTURE.read_text())


def test_mismatch_fixture_inconsistent(mismatch_output: dict) -> None:
    """Mismatch fixture has at least one finding with dom_xpath_visually_consistent=False.

    dom_xpath_visually_consistent is a VLM judgment (not a live DOM query).
    The fixture encodes the expected evaluation result for a known-misaligned bbox.
    """
    inconsistent = [
        f
        for f in mismatch_output["findings"]
        if f["dom_xpath_visually_consistent"] is False
    ]
    assert len(inconsistent) > 0, (
        "Mismatch fixture must contain at least one finding where "
        "dom_xpath_visually_consistent is False"
    )


def test_consistent_fixture_consistent(consistent_output: dict) -> None:
    """Consistent fixture has all findings with dom_xpath_visually_consistent=True."""
    inconsistent = [
        f
        for f in consistent_output["findings"]
        if f["dom_xpath_visually_consistent"] is False
    ]
    assert len(inconsistent) == 0, (
        f"Consistent fixture must have no False dom_xpath_visually_consistent, "
        f"found {len(inconsistent)}"
    )


def test_fixtures_schema_conformant(
    schema: dict, mismatch_output: dict, consistent_output: dict
) -> None:
    """Both DOM-check fixtures validate against the visual-evaluator schema."""
    jsonschema.validate(instance=mismatch_output, schema=schema)
    jsonschema.validate(instance=consistent_output, schema=schema)


def test_mismatch_fixture_inferred_bbox_confidence(mismatch_output: dict) -> None:
    """Mismatch fixture findings with dom_xpath_visually_consistent=False use inferred bbox_confidence."""
    for finding in mismatch_output["findings"]:
        if finding["dom_xpath_visually_consistent"] is False:
            assert finding["bbox_confidence"] == "inferred", (
                "When dom_xpath_visually_consistent is False, bbox_confidence should be inferred "
                "(the VLM could not anchor the bounding box to the named DOM element)"
            )


def test_consistent_fixture_anchored_bbox_confidence(consistent_output: dict) -> None:
    """Consistent fixture findings with dom_xpath_visually_consistent=True use anchored bbox_confidence."""
    for finding in consistent_output["findings"]:
        if finding["dom_xpath_visually_consistent"] is True:
            assert finding["bbox_confidence"] == "anchored", (
                "When dom_xpath_visually_consistent is True, bbox_confidence should be anchored "
                "(the VLM confirmed the bounding box corresponds to the named DOM element)"
            )

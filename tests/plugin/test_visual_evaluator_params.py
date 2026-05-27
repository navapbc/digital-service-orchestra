"""Tests for the visual-evaluator spike artifacts (story 7ff8-04f4-a60c-4cc2).

Validates that:
1. plugins/dso/config/visual-evaluator-params.yaml exists and parses as valid YAML
2. The YAML contains all required inference parameter keys
3. Numeric constraints satisfy the 3.0 MP cap for specified resolutions
4. docs/findings/visual-evaluator-spike.md exists with required section headings
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
PARAMS_YAML_PATH = (
    REPO_ROOT / "plugins" / "dso" / "config" / "visual-evaluator-params.yaml"
)
FINDINGS_MD_PATH = REPO_ROOT / "docs" / "findings" / "visual-evaluator-spike.md"

# 3.0 MP cap in pixels (3,000,000 pixels)
_MP_CAP = 3_000_000

# Resolutions confirmed in Done Definitions
_REQUIRED_RESOLUTIONS = [
    (1280, 800),
    (1440, 900),
]

# Keys required in the YAML config per Done Definitions
_REQUIRED_KEYS = [
    "model_id",
    "temperature",
    "thinking_budget",
    "max_tokens",
    "image_resolution",
]


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def params_yaml():
    """Parse and return the visual-evaluator params YAML."""
    assert PARAMS_YAML_PATH.exists(), (
        f"visual-evaluator-params.yaml not found at {PARAMS_YAML_PATH} — "
        "implementation must create this file (RED phase)"
    )
    with open(PARAMS_YAML_PATH) as f:
        data = yaml.safe_load(f)
    assert isinstance(data, dict), (
        "visual-evaluator-params.yaml must parse as a YAML mapping"
    )
    return data


@pytest.fixture
def findings_text():
    """Read and return the visual-evaluator findings markdown."""
    assert FINDINGS_MD_PATH.exists(), (
        f"visual-evaluator-spike.md not found at {FINDINGS_MD_PATH} — "
        "implementation must create this file (RED phase)"
    )
    return FINDINGS_MD_PATH.read_text()


# ---------------------------------------------------------------------------
# Config YAML: existence and parse validity
# ---------------------------------------------------------------------------


class TestVisualEvaluatorParamsExists:
    """The params YAML file exists and is valid YAML."""

    def test_file_exists(self):
        """YAML config file is present at the declared path."""
        assert PARAMS_YAML_PATH.exists(), f"Missing: {PARAMS_YAML_PATH}"

    def test_parses_as_yaml_mapping(self, params_yaml):
        """File content is a YAML mapping (not a list or scalar)."""
        assert isinstance(params_yaml, dict)


# ---------------------------------------------------------------------------
# Config YAML: required keys
# ---------------------------------------------------------------------------


class TestVisualEvaluatorRequiredKeys:
    """The params YAML contains all keys required by the Done Definitions."""

    @pytest.mark.parametrize("key", _REQUIRED_KEYS)
    def test_required_key_present(self, params_yaml, key):
        """Each required inference parameter key is present in the YAML."""
        assert key in params_yaml, (
            f"Required key '{key}' missing from visual-evaluator-params.yaml"
        )

    def test_model_id_is_string(self, params_yaml):
        """model_id is a non-empty string."""
        model_id = params_yaml.get("model_id")
        assert isinstance(model_id, str) and model_id.strip(), (
            "model_id must be a non-empty string"
        )

    def test_thinking_budget_is_positive_integer(self, params_yaml):
        """thinking_budget is a positive integer (budget_tokens for extended thinking)."""
        budget = params_yaml.get("thinking_budget")
        assert isinstance(budget, int) and budget > 0, (
            f"thinking_budget must be a positive integer, got: {budget!r}"
        )

    def test_max_tokens_is_positive_integer(self, params_yaml):
        """max_tokens is a positive integer."""
        max_tokens = params_yaml.get("max_tokens")
        assert isinstance(max_tokens, int) and max_tokens > 0, (
            f"max_tokens must be a positive integer, got: {max_tokens!r}"
        )

    def test_temperature_is_numeric(self, params_yaml):
        """temperature is a numeric value (int or float)."""
        temp = params_yaml.get("temperature")
        assert isinstance(temp, (int, float)), (
            f"temperature must be numeric, got: {temp!r}"
        )


# ---------------------------------------------------------------------------
# Resolution constraints: both sizes stay under the 3.0 MP cap
# ---------------------------------------------------------------------------


class TestVisualEvaluatorResolutionConstraints:
    """Both required resolutions fit within the 3.0 MP cap per Done Definitions."""

    @pytest.mark.parametrize("width,height", _REQUIRED_RESOLUTIONS)
    def test_resolution_under_mp_cap(self, width, height):
        """Each confirmed resolution (width×height) is strictly below 3,000,000 pixels."""
        megapixels = width * height
        assert megapixels < _MP_CAP, (
            f"{width}x{height} = {megapixels:,} px exceeds the 3.0 MP cap "
            f"({_MP_CAP:,} px)"
        )

    def test_image_resolution_field_present(self, params_yaml):
        """image_resolution key exists in the YAML (holds documented resolution)."""
        assert "image_resolution" in params_yaml, (
            "image_resolution key required in visual-evaluator-params.yaml"
        )


# ---------------------------------------------------------------------------
# Findings markdown: required section headings
# ---------------------------------------------------------------------------


class TestVisualEvaluatorFindingsExists:
    """The findings markdown exists with required section headings."""

    def test_file_exists(self):
        """Findings markdown is present at the declared path."""
        assert FINDINGS_MD_PATH.exists(), f"Missing: {FINDINGS_MD_PATH}"

    def test_has_at_least_one_section_heading(self, findings_text):
        """Findings document has at least one ## section heading."""
        headings = [
            line for line in findings_text.splitlines() if line.startswith("## ")
        ]
        assert headings, (
            "visual-evaluator-spike.md must contain at least one ## section heading"
        )

    def test_has_model_id_section_or_params_section(self, findings_text):
        """Findings document includes a section for API parameters or model details."""
        headings = {
            line.strip()
            for line in findings_text.splitlines()
            if line.startswith("## ") or line.startswith("### ")
        }
        has_relevant_section = any(
            any(
                keyword in h.lower()
                for keyword in ["param", "model", "api", "response", "result", "config"]
            )
            for h in headings
        )
        assert has_relevant_section, (
            "visual-evaluator-spike.md must include a section covering API parameters, "
            "model details, or response (found headings: " + str(headings) + ")"
        )

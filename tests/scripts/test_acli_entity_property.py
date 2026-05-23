"""Tests for AcliClient.set_entity_property and get_entity_property alias methods.

Contract:
  - set_entity_property(issue_key, prop_name, value) delegates to
    set_issue_property(issue_key, prop_name, value) with identical arguments.
  - get_entity_property(issue_key, prop_name) delegates to
    get_issue_property(issue_key, prop_name) with identical arguments and
    returns its result.
  - Both methods exist on AcliClient.

Test: python3 -m pytest tests/scripts/test_acli_entity_property.py
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
ACLI_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "acli-integration.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("acli_integration", ACLI_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def acli() -> ModuleType:
    """Return the acli-integration module."""
    if not ACLI_PATH.exists():
        pytest.fail(
            f"acli-integration.py not found at {ACLI_PATH} — "
            "implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.scripts
def test_acli_client_has_set_entity_property(acli: ModuleType) -> None:
    """AcliClient exposes a set_entity_property method."""
    assert hasattr(acli.AcliClient, "set_entity_property"), (
        "AcliClient is missing set_entity_property"
    )


@pytest.mark.scripts
def test_acli_client_has_get_entity_property(acli: ModuleType) -> None:
    """AcliClient exposes a get_entity_property method."""
    assert hasattr(acli.AcliClient, "get_entity_property"), (
        "AcliClient is missing get_entity_property"
    )


@pytest.mark.scripts
def test_set_entity_property_delegates_to_set_issue_property(
    acli: ModuleType,
) -> None:
    """set_entity_property forwards all args to set_issue_property unchanged."""
    client = acli.AcliClient(
        jira_url="https://jira.example.com",
        user="u",
        api_token="t",
    )
    sentinel_value = {"files": ["src/foo.py"]}
    with patch.object(client, "set_issue_property") as mock_set:
        client.set_entity_property("DSO-42", "dso.impact", sentinel_value)

    mock_set.assert_called_once_with("DSO-42", "dso.impact", sentinel_value)


@pytest.mark.scripts
def test_get_entity_property_delegates_to_get_issue_property(
    acli: ModuleType,
) -> None:
    """get_entity_property forwards all args to get_issue_property and returns its result."""
    client = acli.AcliClient(
        jira_url="https://jira.example.com",
        user="u",
        api_token="t",
    )
    expected_return = {"files": ["src/bar.py"]}
    with patch.object(
        client, "get_issue_property", return_value=expected_return
    ) as mock_get:
        result = client.get_entity_property("DSO-42", "dso.impact")

    mock_get.assert_called_once_with("DSO-42", "dso.impact")
    assert result == expected_return, (
        f"get_entity_property returned {result!r}, expected {expected_return!r}"
    )

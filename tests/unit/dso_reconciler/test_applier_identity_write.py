"""Tests for identity marker writes in create_one() after Jira issue creation.

RED task 0089: verifies that after create_one() successfully creates a Jira issue,
it writes both:
  1. A ``dso-id:<local_id>`` label via client.add_label().
  2. A ``dso_local_id`` entity property via client.set_entity_property().

All tests mock AcliClient so no real Jira calls are made.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from unittest.mock import MagicMock, call

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
APPLIER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "applier.py"
)


def _load_applier():
    spec = importlib.util.spec_from_file_location("applier_identity", APPLIER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["applier_identity"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def applier():
    """Load the applier module, failing all tests if absent."""
    if not APPLIER_PATH.exists():
        pytest.fail(
            f"applier.py not found at {APPLIER_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_applier()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_mock_client(create_return=None):
    """Return a mock AcliClient with create_issue returning a known key."""
    client = MagicMock()
    client.search_issues.return_value = []  # JQL miss — proceed to create
    client.create_issue.return_value = (
        create_return if create_return is not None else {"key": "DIG-999"}
    )
    return client


def _make_create_mutation(local_id: str = "tick-0001") -> dict:
    """Return a minimal create mutation dict."""
    return {
        "action": "create",
        "local_id": local_id,
        "fields": {"summary": f"Reconcile {local_id}", "issuetype": {"name": "Task"}},
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_set_entity_property_called_after_create(applier):
    """After create_one() creates an issue, set_entity_property is called with dso_local_id."""
    local_id = "tick-abc1"
    client = _make_mock_client(create_return={"key": "DIG-999"})
    mutation = _make_create_mutation(local_id)

    applier.create_one(mutation, client, rest_calls=0)

    client.set_entity_property.assert_called_once_with("DIG-999", "dso_local_id", local_id)


def test_add_label_called_after_create(applier):
    """After create_one() creates an issue, add_label is called with dso-id:<local_id>."""
    local_id = "tick-abc2"
    client = _make_mock_client(create_return={"key": "DIG-999"})
    mutation = _make_create_mutation(local_id)

    applier.create_one(mutation, client, rest_calls=0)

    client.add_label.assert_called_once_with("DIG-999", f"dso-id:{local_id}")


def test_identity_writes_use_correct_jira_key(applier):
    """Identity writes target the key returned by create_issue, not a hardcoded value."""
    local_id = "tick-abc3"
    client = _make_mock_client(create_return={"key": "PROJ-42"})
    mutation = _make_create_mutation(local_id)

    applier.create_one(mutation, client, rest_calls=0)

    client.add_label.assert_called_once_with("PROJ-42", f"dso-id:{local_id}")
    client.set_entity_property.assert_called_once_with("PROJ-42", "dso_local_id", local_id)


def test_identity_writes_not_called_on_dedup_skip(applier, tmp_path):
    """When JQL dedup fires (issue already exists), identity writes are NOT called."""
    existing = {"key": "DIG-500", "fields": {"summary": "existing"}}
    client = _make_mock_client()
    client.search_issues.return_value = [existing]  # JQL hit
    mutation = _make_create_mutation("tick-abc4")

    applier.create_one(mutation, client, rest_calls=0, repo_root=tmp_path)

    client.add_label.assert_not_called()
    client.set_entity_property.assert_not_called()


def test_identity_writes_not_called_on_budget_defer(applier):
    """When budget guard fires (rest_calls >= 200), identity writes are NOT called."""
    client = _make_mock_client()
    mutation = _make_create_mutation("tick-abc5")

    result = applier.create_one(mutation, client, rest_calls=200)

    assert result is None
    client.add_label.assert_not_called()
    client.set_entity_property.assert_not_called()


def test_label_written_before_entity_property(applier):
    """add_label is called before set_entity_property (label first, then property)."""
    local_id = "tick-abc6"
    call_order: list[str] = []

    client = MagicMock()
    client.search_issues.return_value = []
    client.create_issue.return_value = {"key": "DIG-999"}
    client.add_label.side_effect = lambda *a, **kw: call_order.append("add_label")
    client.set_entity_property.side_effect = (
        lambda *a, **kw: call_order.append("set_entity_property")
    )

    mutation = _make_create_mutation(local_id)
    applier.create_one(mutation, client, rest_calls=0)

    assert call_order == ["add_label", "set_entity_property"], (
        f"Expected add_label before set_entity_property, got: {call_order}"
    )

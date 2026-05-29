"""Tests for the _apply_outbound_update v1 leaf in dso_reconciler/applier.py.

Behavior under test:
  - Allowlisted fields (summary, description, assignee, priority) are pushed via
    client.update_issue, routed through _call_with_retry.
  - Non-allowlisted fields are silently dropped — zero side-effects on those.
  - Status field is governed by DSO_RECONCILER_STATUS_GATING:
      * gating != "1": raise StatusMappingError, zero side-effects.
      * gating == "1": delegate to _route_status_via_draft5, strip status
        before pushing remaining allowlisted fields.

NOTE: The outbound differ emits Jira-side field names (e.g. "summary" not
"title"). Tests use "summary" to match the real mutation payloads.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
APPLIER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "applier.py"
)


def _load_applier():
    spec = importlib.util.spec_from_file_location("applier", APPLIER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["applier"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def applier():
    return _load_applier()


def _make_outbound_update_mutation(applier_mod, changed_fields):
    mut_mod = applier_mod._load_mutation_module()
    return mut_mod.Mutation(
        direction=mut_mod.MutationDirection.outbound,
        action=mut_mod.MutationAction.update,
        target="PROJ-200",
        payload={"changed_fields": changed_fields},
        provenance={"source": "test"},
    )


def test_allowlist_fields_routed_via_call_with_retry(applier):
    """Allowlisted fields are pushed via _call_with_retry → client.update_issue."""
    client = SimpleNamespace(update_issue=MagicMock(return_value=None))
    mutation = _make_outbound_update_mutation(
        applier, {"summary": "new title", "description": "new desc"}
    )

    captured: list[tuple] = []
    real = applier._call_with_retry

    def spy(fn, *args, **kwargs):
        captured.append((fn, args, kwargs))
        return real(fn, *args, **kwargs)

    with patch.object(applier, "_call_with_retry", side_effect=spy):
        result = applier._apply_outbound_update(mutation, client=client)

    # Verify update_issue invoked exactly once with the allowlisted subset.
    update_calls = [c for c in captured if c[0] is client.update_issue]
    assert len(update_calls) == 1, f"expected 1 update_issue call, got {len(update_calls)}"
    _, args, kwargs = update_calls[0]
    assert args == ("PROJ-200",)
    assert set(kwargs.keys()) == {"summary", "description"}
    assert kwargs["summary"] == "new title"
    assert kwargs["description"] == "new desc"

    # ApplyResult reports which fields were pushed.
    assert result.payload == {"fields_pushed": ["description", "summary"]}


def test_non_allowlist_fields_silently_dropped(applier):
    """Fields outside the allowlist are dropped — no client call when the
    filtered set is empty."""
    client = SimpleNamespace(update_issue=MagicMock(return_value=None))
    mutation = _make_outbound_update_mutation(
        applier, {"labels": ["should-drop"], "custom_field": "x"}
    )

    result = applier._apply_outbound_update(mutation, client=client)

    assert client.update_issue.call_count == 0
    assert result.payload == {"fields_pushed": []}


def test_status_field_is_forwarded_to_update_issue(applier, monkeypatch):
    """Bug 85a1 (Gap 8): the DSO_RECONCILER_STATUS_GATING gate has been
    removed. Status is now first-class — ``_apply_outbound_update`` passes
    it through to ``client.update_issue`` (which routes status to
    ``transition_issue`` → REST POST /transitions inside acli-integration).
    """
    monkeypatch.delenv("DSO_RECONCILER_STATUS_GATING", raising=False)
    client = SimpleNamespace(update_issue=MagicMock(return_value=None))
    mutation = _make_outbound_update_mutation(
        applier, {"status": "Done", "summary": "x"}
    )

    applier._apply_outbound_update(mutation, client=client)

    # update_issue called with BOTH summary and status — status is no longer
    # stripped, and no StatusMappingError is raised.
    assert client.update_issue.call_count == 1
    args, kwargs = client.update_issue.call_args
    assert args == ("PROJ-200",)
    assert kwargs.get("summary") == "x"
    assert kwargs.get("status") == "Done"


def test_status_only_payload_still_pushes(applier, monkeypatch):
    """A mutation whose only changed field is status reaches client.update_issue.

    Previously the gating prevented any update_issue call when status was the
    sole field; the new contract pushes it.
    """
    monkeypatch.delenv("DSO_RECONCILER_STATUS_GATING", raising=False)
    client = SimpleNamespace(update_issue=MagicMock(return_value=None))
    mutation = _make_outbound_update_mutation(applier, {"status": "Done"})

    result = applier._apply_outbound_update(mutation, client=client)

    assert client.update_issue.call_count == 1
    _, kwargs = client.update_issue.call_args
    assert kwargs == {"status": "Done"}
    assert result.payload == {"fields_pushed": ["status"]}

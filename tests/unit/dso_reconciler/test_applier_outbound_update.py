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


def test_status_gating_off_raises_no_side_effects(applier, monkeypatch):
    """When DSO_RECONCILER_STATUS_GATING is unset/!=1, touching status raises
    StatusMappingError with zero side-effects."""
    monkeypatch.delenv("DSO_RECONCILER_STATUS_GATING", raising=False)
    client = SimpleNamespace(update_issue=MagicMock(return_value=None))
    mutation = _make_outbound_update_mutation(
        applier, {"status": "Done", "summary": "x"}
    )

    errs = applier._load_errors_module()
    with pytest.raises(errs.StatusMappingError):
        applier._apply_outbound_update(mutation, client=client)

    # Zero side-effects: update_issue must NOT have been called.
    assert client.update_issue.call_count == 0


def test_status_gating_explicit_zero_raises(applier, monkeypatch):
    """An explicit '0' gating value also raises (only '1' opens the gate)."""
    monkeypatch.setenv("DSO_RECONCILER_STATUS_GATING", "0")
    client = SimpleNamespace(update_issue=MagicMock(return_value=None))
    mutation = _make_outbound_update_mutation(applier, {"status": "Done"})

    errs = applier._load_errors_module()
    with pytest.raises(errs.StatusMappingError):
        applier._apply_outbound_update(mutation, client=client)
    assert client.update_issue.call_count == 0


def test_status_gating_on_delegates_to_draft5_and_strips_status(applier, monkeypatch):
    """When gating == '1', status is routed via _route_status_via_draft5 and
    stripped before the remaining allowlisted fields are pushed."""
    monkeypatch.setenv("DSO_RECONCILER_STATUS_GATING", "1")
    client = SimpleNamespace(update_issue=MagicMock(return_value=None))
    mutation = _make_outbound_update_mutation(
        applier, {"status": "Done", "summary": "x"}
    )

    with patch.object(applier, "_route_status_via_draft5") as spy:
        applier._apply_outbound_update(mutation, client=client)

    spy.assert_called_once()
    # summary (allowlisted) still pushed via update_issue (status stripped).
    assert client.update_issue.call_count == 1
    args, kwargs = client.update_issue.call_args
    assert args == ("PROJ-200",)
    assert "summary" in kwargs
    assert kwargs["summary"] == "x"
    assert "status" not in kwargs


def test_status_only_with_gating_on_no_update_issue_call(applier, monkeypatch):
    """If the only touched field is status (gating on), no update_issue call
    is made — status routing went through the draft5 stub."""
    monkeypatch.setenv("DSO_RECONCILER_STATUS_GATING", "1")
    client = SimpleNamespace(update_issue=MagicMock(return_value=None))
    mutation = _make_outbound_update_mutation(applier, {"status": "Done"})

    with patch.object(applier, "_route_status_via_draft5") as spy:
        result = applier._apply_outbound_update(mutation, client=client)

    spy.assert_called_once()
    assert client.update_issue.call_count == 0
    assert result.payload == {"fields_pushed": []}

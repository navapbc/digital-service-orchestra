"""Unit tests for dso_reconciler/inbound_differ.py.

Tests the inbound differ that detects Jira-side changes for bound tickets
and emits InboundMutation objects for changes to apply locally.

Uses the importlib spec_from_file_location pattern established in the
reconciler test tree (see conftest.py docstring for rationale).
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
INBOUND_DIFFER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "inbound_differ.py"
)


def _load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def inbound_differ() -> ModuleType:
    return _load_module("inbound_differ", INBOUND_DIFFER_PATH)


# ---------------------------------------------------------------------------
# Stub BindingStore
# ---------------------------------------------------------------------------


class StubBindingStore:
    """In-memory binding store for tests (inbound direction)."""

    def __init__(self, bindings: dict[str, str] | None = None) -> None:
        # bindings: {jira_key: local_id}
        self._bindings: dict[str, str] = bindings or {}

    def get_local_id(self, jira_key: str) -> str | None:
        return self._bindings.get(jira_key)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_bound_ticket_jira_changed_emits_inbound_update(
    inbound_differ: ModuleType,
) -> None:
    """Bound ticket where Jira title differs from local -> inbound update."""
    jira_snapshot = {
        "PROJ-100": {
            "summary": "Updated from Jira",
            "description": "Same desc",
            "issuetype": "Bug",
            "priority": "Medium",
            "status": "To Do",
            "assignee": "alice",
            "labels": [],
        }
    }
    store = StubBindingStore({"PROJ-100": "local-1"})
    local_tickets = {
        "local-1": {
            "title": "Original title",
            "description": "Same desc",
            "ticket_type": "bug",
            "priority": 2,
            "status": "open",
            "assignee": "alice",
            "tags": [],
        }
    }

    result, suppressed = inbound_differ.compute_inbound_mutations(
        jira_snapshot=jira_snapshot,
        binding_store=store,
        local_tickets_by_id=local_tickets,
    )

    assert len(result) == 1
    assert suppressed == 0
    m = result[0]
    assert m.jira_key == "PROJ-100"
    assert m.local_id == "local-1"
    assert m.action == "update"
    assert m.fields == {"title": "Updated from Jira"}


def test_unbound_jira_issue_ignored(inbound_differ: ModuleType) -> None:
    """Unbound Jira issue -> no inbound mutation (local is source of truth)."""
    jira_snapshot = {
        "PROJ-200": {
            "summary": "Some Jira issue",
            "description": "",
            "issuetype": "Task",
            "priority": "Medium",
            "status": "To Do",
            "assignee": "",
            "labels": [],
        }
    }
    store = StubBindingStore()  # no bindings
    local_tickets: dict = {}

    result, suppressed = inbound_differ.compute_inbound_mutations(
        jira_snapshot=jira_snapshot,
        binding_store=store,
        local_tickets_by_id=local_tickets,
    )

    assert result == []
    assert suppressed == 0


def test_bound_both_changed_skipped(inbound_differ: ModuleType) -> None:
    """When both local and Jira changed, the inbound differ still emits.

    Local-wins conflict resolution is enforced at the orchestrator level:
    the outbound differ's mutation takes precedence. The inbound differ
    does not have access to a baseline snapshot to detect local changes,
    so it emits the diff and lets the orchestrator resolve conflicts.

    In practice, when both sides changed, the outbound differ will push
    the local value (local wins), and the inbound mutation will be
    superseded by the outbound mutation during apply ordering.
    """
    jira_snapshot = {
        "PROJ-100": {
            "summary": "Jira changed title",
            "description": "Same",
            "issuetype": "Bug",
            "priority": "High",  # Jira changed priority too
            "status": "To Do",
            "assignee": "alice",
            "labels": [],
        }
    }
    store = StubBindingStore({"PROJ-100": "local-1"})
    local_tickets = {
        "local-1": {
            "title": "Local changed title",  # local also changed
            "description": "Same",
            "ticket_type": "bug",
            "priority": 1,  # local also changed priority
            "status": "open",
            "assignee": "alice",
            "tags": [],
        }
    }

    result, suppressed = inbound_differ.compute_inbound_mutations(
        jira_snapshot=jira_snapshot,
        binding_store=store,
        local_tickets_by_id=local_tickets,
    )

    # The inbound differ emits the diff. The orchestrator resolves conflicts
    # by giving outbound mutations precedence (local wins).
    assert len(result) == 1
    assert suppressed == 0
    m = result[0]
    # The title differs (Jira says "Jira changed title", local says "Local changed title")
    assert "title" in m.fields
    assert m.fields["title"] == "Jira changed title"


def test_bound_no_changes_emits_nothing(inbound_differ: ModuleType) -> None:
    """Bound ticket where Jira fields match local -> no mutation."""
    jira_snapshot = {
        "PROJ-100": {
            "summary": "Same title",
            "description": "Same desc",
            "issuetype": "Task",
            "priority": "Medium",
            "status": "In Progress",
            "assignee": "bob",
            "labels": ["shared-label"],
        }
    }
    store = StubBindingStore({"PROJ-100": "local-1"})
    local_tickets = {
        "local-1": {
            "title": "Same title",
            "description": "Same desc",
            "ticket_type": "task",
            "priority": 2,
            "status": "in_progress",
            "assignee": "bob",
            "tags": ["shared-label"],
        }
    }

    result, suppressed = inbound_differ.compute_inbound_mutations(
        jira_snapshot=jira_snapshot,
        binding_store=store,
        local_tickets_by_id=local_tickets,
    )

    assert result == []
    assert suppressed == 0


def test_inbound_label_diff(inbound_differ: ModuleType) -> None:
    """Jira has a label that local doesn't -> inbound label add."""
    jira_snapshot = {
        "PROJ-100": {
            "summary": "Same",
            "description": "Same",
            "issuetype": "Task",
            "priority": "Medium",
            "status": "To Do",
            "assignee": "",
            "labels": ["jira-label", "shared"],
        }
    }
    store = StubBindingStore({"PROJ-100": "local-1"})
    local_tickets = {
        "local-1": {
            "title": "Same",
            "description": "Same",
            "ticket_type": "task",
            "priority": 2,
            "status": "open",
            "assignee": "",
            "tags": ["shared"],
        }
    }

    result, suppressed = inbound_differ.compute_inbound_mutations(
        jira_snapshot=jira_snapshot,
        binding_store=store,
        local_tickets_by_id=local_tickets,
    )

    assert len(result) == 1
    assert suppressed == 0
    m = result[0]
    label_adds = [lb for lb in m.labels if lb["action"] == "add"]
    assert any(lb["label"] == "jira-label" for lb in label_adds)

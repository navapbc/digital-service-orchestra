"""Bug 3bf8: inbound differ must suppress mutations that contradict outbound.

In a single bidirectional pass, outbound and inbound differs both run
against the same pre-pass snapshot. When the local side has just added a
label (or changed a scalar field), outbound correctly emits ADD-X but
without coordination the inbound differ emits REMOVE-X (since the
snapshot shows Jira lacking X). The apply pass then runs both and the
inbound EDIT clobbers the local-side change.

Fix: ``compute_inbound_mutations`` accepts an optional
``outbound_mutations`` parameter and filters its emissions so that:
  - label ADD is suppressed when outbound is REMOVING the same label
    for the same jira_key
  - label REMOVE is suppressed when outbound is ADDING the same label
    for the same jira_key
  - scalar field updates are suppressed when outbound is updating the
    same field on the same jira_key

The local-side change wins for the pass; the next pass converges both
sides without a phase-2 snapshot refresh.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
INBOUND_DIFFER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "inbound_differ.py"
)
OUTBOUND_DIFFER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "outbound_differ.py"
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
    return _load_module("inbound_differ_bidir", INBOUND_DIFFER_PATH)


@pytest.fixture(scope="module")
def outbound_differ() -> ModuleType:
    return _load_module("outbound_differ_bidir", OUTBOUND_DIFFER_PATH)


class StubBindingStore:
    def __init__(self, bindings: dict[str, str] | None = None) -> None:
        # bindings: {jira_key: local_id}
        self._bindings: dict[str, str] = bindings or {}

    def get_local_id(self, jira_key: str) -> str | None:
        return self._bindings.get(jira_key)


def _baseline_local(label_list: list[str]) -> dict:
    return {
        "title": "T",
        "description": "D",
        "ticket_type": "task",
        "priority": 2,
        "status": "open",
        "assignee": "alice",
        "tags": label_list,
    }


def _baseline_jira(label_list: list[str]) -> dict:
    return {
        "summary": "T",
        "description": "D",
        "issuetype": "Task",
        "priority": "Medium",
        "status": "To Do",
        "assignee": "alice",
        "labels": label_list,
    }


# ---------------------------------------------------------------------------
# Label coordination tests
# ---------------------------------------------------------------------------


def test_inbound_remove_suppressed_when_outbound_adds_same_label(
    inbound_differ: ModuleType, outbound_differ: ModuleType
) -> None:
    """Local just added 'ob-added'; outbound emits ADD; inbound must NOT emit REMOVE."""
    jira_snapshot = {"PROJ-1": _baseline_jira(["labelprobe"])}
    local_tickets = {"local-1": _baseline_local(["labelprobe", "ob-added"])}
    store = StubBindingStore({"PROJ-1": "local-1"})

    outbound_mutations = [
        outbound_differ.OutboundMutation(
            local_id="local-1",
            jira_key="PROJ-1",
            action="update",
            fields={},
            labels=[{"action": "add", "label": "ob-added"}],
        )
    ]

    result = inbound_differ.compute_inbound_mutations(
        jira_snapshot=jira_snapshot,
        binding_store=store,
        local_tickets_by_id=local_tickets,
        outbound_mutations=outbound_mutations,
    )

    # Inbound must not emit a REMOVE for 'ob-added'.
    for m in result:
        for lm in m.labels:
            assert not (
                lm.get("action") == "remove" and lm.get("label") == "ob-added"
            ), f"Inbound emitted contradictory REMOVE ob-added: {m}"


def test_inbound_add_suppressed_when_outbound_removes_same_label(
    inbound_differ: ModuleType, outbound_differ: ModuleType
) -> None:
    """Local just removed 'ib-add'; outbound emits REMOVE; inbound must NOT emit ADD."""
    # Local lacks 'ib-add'; Jira still has it (local-side change is fresher).
    jira_snapshot = {"PROJ-2": _baseline_jira(["labelprobe", "ib-add"])}
    local_tickets = {"local-2": _baseline_local(["labelprobe"])}
    store = StubBindingStore({"PROJ-2": "local-2"})

    outbound_mutations = [
        outbound_differ.OutboundMutation(
            local_id="local-2",
            jira_key="PROJ-2",
            action="update",
            fields={},
            labels=[{"action": "remove", "label": "ib-add"}],
        )
    ]

    result = inbound_differ.compute_inbound_mutations(
        jira_snapshot=jira_snapshot,
        binding_store=store,
        local_tickets_by_id=local_tickets,
        outbound_mutations=outbound_mutations,
    )

    for m in result:
        for lm in m.labels:
            assert not (lm.get("action") == "add" and lm.get("label") == "ib-add"), (
                f"Inbound emitted contradictory ADD ib-add: {m}"
            )


def test_inbound_scalar_field_suppressed_when_outbound_updates_same_field(
    inbound_differ: ModuleType, outbound_differ: ModuleType
) -> None:
    """Local just changed description; outbound emits update for it; inbound must NOT echo back the old value."""
    jira_snapshot = {
        "PROJ-3": {
            "summary": "T",
            "description": "old jira desc",
            "issuetype": "Task",
            "priority": "Medium",
            "status": "To Do",
            "assignee": "alice",
            "labels": [],
        }
    }
    local_tickets = {
        "local-3": {
            "title": "T",
            "description": "new local desc",
            "ticket_type": "task",
            "priority": 2,
            "status": "open",
            "assignee": "alice",
            "tags": [],
        }
    }
    store = StubBindingStore({"PROJ-3": "local-3"})

    outbound_mutations = [
        outbound_differ.OutboundMutation(
            local_id="local-3",
            jira_key="PROJ-3",
            action="update",
            fields={"description": "new local desc"},
            labels=[],
        )
    ]

    result = inbound_differ.compute_inbound_mutations(
        jira_snapshot=jira_snapshot,
        binding_store=store,
        local_tickets_by_id=local_tickets,
        outbound_mutations=outbound_mutations,
    )

    for m in result:
        assert "description" not in m.fields, (
            f"Inbound emitted contradictory description update: {m}"
        )


# ---------------------------------------------------------------------------
# Backward-compat: existing callers (no outbound_mutations) still work.
# ---------------------------------------------------------------------------


def test_default_outbound_mutations_param_preserves_legacy_behavior(
    inbound_differ: ModuleType,
) -> None:
    """Without outbound_mutations, behavior matches pre-fix semantics."""
    jira_snapshot = {"PROJ-9": _baseline_jira(["only-on-jira"])}
    local_tickets = {"local-9": _baseline_local([])}
    store = StubBindingStore({"PROJ-9": "local-9"})

    result = inbound_differ.compute_inbound_mutations(
        jira_snapshot=jira_snapshot,
        binding_store=store,
        local_tickets_by_id=local_tickets,
    )

    assert len(result) == 1
    add_labels = [lm for lm in result[0].labels if lm.get("action") == "add"]
    assert any(lm.get("label") == "only-on-jira" for lm in add_labels)

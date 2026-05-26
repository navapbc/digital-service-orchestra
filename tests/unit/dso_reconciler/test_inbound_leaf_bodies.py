"""Story bd19-d744-b8c7-4079 — observable-behaviour tests for the 5 inbound
applier leaves.

Each test builds a Mutation, invokes applier.apply() against an isolated
fixture tracker directory, and asserts the documented side effect (event
file, directory rename, follow-on payload, client call).
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest


REPO_ROOT = Path(__file__).resolve().parents[3]
APPLIER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "applier.py"
)
MUTATION_PATH = APPLIER_PATH.parent / "mutation.py"


def _load_mutation_module():
    # Load under the canonical key used by applier.py so that Mutation
    # objects created here share class identity with the applier-side enum
    # members (avoids _direction_guard 'is' check failures).
    canonical = "plugins.dso.scripts.dso_reconciler.mutation"
    if canonical in sys.modules:
        return sys.modules[canonical]
    spec = importlib.util.spec_from_file_location(canonical, MUTATION_PATH)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[canonical] = mod
    spec.loader.exec_module(mod)
    return mod


def _load_applier():
    spec = importlib.util.spec_from_file_location("applier_under_test", APPLIER_PATH)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["applier_under_test"] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def mut_mod():
    return _load_mutation_module()


@pytest.fixture(scope="module")
def applier():
    return _load_applier()


@pytest.fixture
def fixture_repo(tmp_path, monkeypatch):
    """A minimal repo layout with an initialised .tickets-tracker dir.

    Removes TICKETS_TRACKER_DIR from the environment so a developer-set
    override in the host shell cannot leak into the test and steer writes
    away from the tmp tracker dir (PR #375 review thread 3306949620).
    """
    monkeypatch.delenv("TICKETS_TRACKER_DIR", raising=False)
    tracker = tmp_path / ".tickets-tracker"
    tracker.mkdir()
    (tracker / ".env-id").write_text("test-env-id", encoding="utf-8")
    return tmp_path


def _make_mutation(
    mut_mod, *, direction, action, target, payload=None, provenance=None
):
    return mut_mod.Mutation(
        direction=direction,
        action=action,
        target=target,
        payload=payload or {},
        provenance=provenance or {"source": "test"},
    )


def _event_files(tracker_dir: Path, local_id: str) -> list[Path]:
    return sorted((tracker_dir / local_id).glob("*.json"))


def _read_create(tracker_dir: Path, local_id: str) -> dict:
    for path in _event_files(tracker_dir, local_id):
        ev = json.loads(path.read_text())
        if ev.get("event_type") == "CREATE":
            return ev
    raise AssertionError(f"no CREATE event in {tracker_dir / local_id}")


# ---------------------------------------------------------------------------
# 1. inbound create
# ---------------------------------------------------------------------------


def test_inbound_create_writes_local_ticket(applier, mut_mod, fixture_repo):
    mutation = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.create,
        target="DIG-123",
        payload={
            "fields": {
                "summary": "X",
                "priority": 2,
                "status": "To Do",
                "issuetype": "Task",
            },
            "labels": [],
        },
    )
    result = applier._apply_typed(mutation, repo_root=fixture_repo)

    tracker = fixture_repo / ".tickets-tracker"
    local_id = "jira-dig-123"
    assert (tracker / local_id).is_dir()
    create_ev = _read_create(tracker, local_id)
    data = create_ev["data"]
    assert data["title"] == "X"
    assert data["priority"] == 2
    assert data["ticket_type"] == "task"
    assert "imported:reconciler-bootstrap" in data["tags"]
    assert result.payload["local_id"] == local_id


def test_inbound_create_via_leaves_registry(applier, mut_mod):
    """Pin the dispatch path: _LEAVES[(inbound, create)] resolves to the leaf."""
    key = (mut_mod.MutationDirection.inbound, mut_mod.MutationAction.create)
    assert applier._LEAVES[key] is applier._apply_inbound_create


# ---------------------------------------------------------------------------
# 2. inbound update
# ---------------------------------------------------------------------------


def test_inbound_update_writes_edit_event(applier, mut_mod, fixture_repo):
    # Seed an existing ticket dir via inbound create.
    create_mut = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.create,
        target="DIG-123",
        payload={"fields": {"summary": "Original", "issuetype": "Task"}},
    )
    applier._apply_typed(create_mut, repo_root=fixture_repo)

    update_mut = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.update,
        target="jira-dig-123",
        payload={"fields": {"summary": "Y"}},
    )
    result = applier._apply_typed(update_mut, repo_root=fixture_repo)

    tracker = fixture_repo / ".tickets-tracker"
    edits = [
        json.loads(p.read_text())
        for p in _event_files(tracker, "jira-dig-123")
        if "EDIT" in p.name
    ]
    assert edits, "expected at least one EDIT event"
    assert edits[-1]["data"]["fields"]["title"] == "Y"
    assert result.payload["local_id"] == "jira-dig-123"


def test_inbound_update_status_event_uses_previous_status_not_new(
    applier, mut_mod, fixture_repo
):
    """STATUS event's current_status must be the PREVIOUS state, not the new
    one (PR #375 review thread 3306949587). The reducer compares
    data['current_status'] against state['status'] to detect forks — setting
    current_status to the NEW state guarantees a false-positive fork mismatch
    whenever the ticket isn't already in that state.
    """
    # Seed via inbound create (no status -> stays at reducer default 'open').
    create_mut = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.create,
        target="DIG-321",
        payload={"fields": {"summary": "S", "issuetype": "Task"}},
    )
    applier._apply_typed(create_mut, repo_root=fixture_repo)

    # Now inbound update transitions the Jira status to 'In Progress' ->
    # 'in_progress' locally (assuming config maps it; if config lacks the
    # entry, _jira_status_to_local returns 'open' and we still assert the
    # invariant: current_status != status when they differ).
    update_mut = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.update,
        target="jira-dig-321",
        payload={"fields": {"status": "In Progress"}},
    )
    applier._apply_typed(update_mut, repo_root=fixture_repo)

    tracker = fixture_repo / ".tickets-tracker"
    status_events = [
        json.loads(p.read_text())
        for p in _event_files(tracker, "jira-dig-321")
        if "STATUS" in p.name
    ]
    assert status_events, "expected a STATUS event from inbound update"
    latest = status_events[-1]["data"]
    # current_status must be the PREVIOUS state ('open' — seeded default),
    # NOT the new target. If new == previous (degenerate self-transition),
    # the two can coincide, but in this fixture they must differ.
    new_status = latest["status"]
    prev_status = latest["current_status"]
    assert prev_status == "open", (
        f"expected current_status='open' (prior state), got {prev_status!r}"
    )
    if new_status != "open":
        assert new_status != prev_status, (
            "current_status (previous state) must differ from status (new state)"
        )


# ---------------------------------------------------------------------------
# 3. inbound delete — four probe-outcome branches
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "outcome",
    ["hard_delete", "redirect", "out_of_window", "trash"],
)
def test_inbound_delete_branches(applier, mut_mod, fixture_repo, outcome):
    # Seed the ticket dir.
    create_mut = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.create,
        target="DIG-123",
        payload={"fields": {"summary": "seed", "issuetype": "Task"}},
    )
    applier._apply_typed(create_mut, repo_root=fixture_repo)

    payload = {"probe_outcome": outcome}
    if outcome == "redirect":
        payload["new_jira_key"] = "DIG-999"
    delete_mut = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.delete,
        target="jira-dig-123",
        payload=payload,
    )
    result = applier._apply_typed(delete_mut, repo_root=fixture_repo)
    assert result.payload["branch"] == outcome

    tracker = fixture_repo / ".tickets-tracker"
    if outcome == "hard_delete":
        assert result.payload["follow_on"]["action"] == "create_after_hard_delete"
    elif outcome == "redirect":
        assert (tracker / "jira-dig-999").is_dir()
        assert not (tracker / "jira-dig-123").exists()
    else:
        # Comment-only branches: ticket dir still exists with a new COMMENT.
        events = _event_files(tracker, "jira-dig-123")
        assert any("COMMENT" in p.name for p in events)


# ---------------------------------------------------------------------------
# 4. inbound repair_property — wires through to inbound_repair_property
# ---------------------------------------------------------------------------


def test_inbound_repair_property_invokes_client(applier, mut_mod):
    client = MagicMock()
    mutation = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.repair_property,
        target="DIG-X",
        payload={"local_id": "L"},
    )
    result = applier._apply_typed(mutation, client=client)
    client.set_issue_property.assert_called_once_with("DIG-X", "dso_local_id", "L")
    assert result.payload.get("status") == "ok"


# ---------------------------------------------------------------------------
# 5. inbound conflict — emits suppress_pair follow-on, files a bug
# ---------------------------------------------------------------------------


def test_inbound_conflict_emits_suppress_pair(
    applier, mut_mod, fixture_repo, monkeypatch
):
    # Make the bug-file subprocess a no-op so the test does not depend on the
    # ticket CLI being available inside the fixture tree.
    called = {}

    def fake_file_bug(cli_path, title, description, parent_id):
        called["title"] = title
        return "bug-id-1234"

    monkeypatch.setattr(applier, "_file_conflict_bug_ticket", fake_file_bug)

    mutation = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.conflict,
        target="DIG-7",
        payload={"local_id": "jira-dig-7", "reason": "dual-write divergence"},
    )
    result = applier._apply_typed(mutation, repo_root=fixture_repo)
    follow_on = result.payload["follow_on"]
    assert follow_on["kind"] == "suppress_pair"
    assert follow_on["jira_key"] == "DIG-7"
    assert follow_on["local_id"] == "jira-dig-7"


def test_apply_honours_suppress_pair_drops_subsequent_inbound(
    applier, mut_mod, fixture_repo, monkeypatch
):
    """reconcile_once → applier.apply contract: an inbound conflict on a pair
    must suppress later inbound mutations on the same pair in the same pass.
    """

    monkeypatch.setattr(applier, "_file_conflict_bug_ticket", lambda *a, **k: "bug-1")

    # Seed the ticket dir so updates would otherwise apply.
    create = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.create,
        target="DIG-7",
        payload={"fields": {"summary": "seed", "issuetype": "Task"}},
    )
    applier._apply_typed(create, repo_root=fixture_repo)

    conflict = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.conflict,
        target="DIG-7",
        payload={"local_id": "jira-dig-7", "reason": "test"},
    )
    update_1 = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.update,
        target="jira-dig-7",
        payload={"fields": {"summary": "STOMP-1"}},
    )
    update_2 = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.update,
        target="jira-dig-7",
        payload={"fields": {"summary": "STOMP-2"}},
    )

    applier.apply(
        [conflict, update_1, update_2], pass_id="test-pass", repo_root=fixture_repo
    )

    # The two STOMP updates should NOT have produced EDIT events.
    tracker = fixture_repo / ".tickets-tracker"
    edits = [
        json.loads(p.read_text())
        for p in _event_files(tracker, "jira-dig-7")
        if "EDIT" in p.name
    ]
    titles = [e["data"]["fields"].get("title", "") for e in edits]
    assert "STOMP-1" not in titles
    assert "STOMP-2" not in titles


def test_apply_honours_suppress_pair_drops_subsequent_inbound_via_computed_form(
    applier, mut_mod, fixture_repo, monkeypatch
):
    """Computed-form suppression contract (PR #375 review thread 3306949607):
    a suppress_pair on jira_key='DIG-7' must also drop later mutations whose
    target is the LOCAL-ID form of that key ('jira-dig-7'). Without the
    third match-arm, the later inbound update sneaks past.
    """
    monkeypatch.setattr(applier, "_file_conflict_bug_ticket", lambda *a, **k: "bug-1")

    # Seed the ticket dir so an EDIT could otherwise be written.
    create = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.create,
        target="DIG-7",
        payload={"fields": {"summary": "seed", "issuetype": "Task"}},
    )
    applier._apply_typed(create, repo_root=fixture_repo)

    # Conflict mutation targets the JIRA-key form...
    conflict = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.conflict,
        target="DIG-7",
        payload={"local_id": "", "reason": "test"},
    )
    # ...and the follow_on records local_id='' so only the jira_key arm
    # ('DIG-7') and its computed local-id form ('jira-dig-7') drive
    # suppression. The later mutation uses the computed-form target.
    later = _make_mutation(
        mut_mod,
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.update,
        target="jira-dig-7",
        payload={"fields": {"summary": "SHOULD-BE-DROPPED"}},
    )

    applier.apply([conflict, later], pass_id="test-pass", repo_root=fixture_repo)

    tracker = fixture_repo / ".tickets-tracker"
    edits = [
        json.loads(p.read_text())
        for p in _event_files(tracker, "jira-dig-7")
        if "EDIT" in p.name
    ]
    titles = [e["data"]["fields"].get("title", "") for e in edits]
    assert "SHOULD-BE-DROPPED" not in titles

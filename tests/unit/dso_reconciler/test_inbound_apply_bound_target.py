"""Tests for `_apply_inbound_update` field/target pipeline (bug 1bb2-5da5).

Behaviour under test (observable via on-disk events):

  1. When payload includes ``local_id`` (set by reconcile.py for bound
     tickets), the EDIT event is written under that local UUID directory —
     NOT a ``jira-dig-NNN/`` directory derived from ``mutation.target``.
     This prevents duplicate ticket creation + silent data loss when the
     reconciler updates a bound UUID ticket from Jira.
  2. The applier accepts the differ's LOCAL-keyed field shape
     (``title``, ``ticket_type``) — the inbound differ has already mapped
     Jira → local names. Both the new local-keyed names AND the legacy
     ``summary`` (Jira-keyed) name are accepted for back-compat.
  3. ADF (Atlassian Document Format) description dicts are normalized to
     plain text before being written. Without normalization, the EDIT
     event would carry the raw ADF dict and the reducer would store the
     description as a `dict`, not a string.
  4. When ``status`` arrives already mapped to a local value
     (``"open"`` / ``"in_progress"`` / ``"done"`` / ``"closed"``), the
     applier does NOT re-run the Jira→local mapper (which would double-
     map e.g. ``"in_progress"`` → empty/garbage).
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

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


def _make_mutation(applier, target: str, payload: dict):
    mut_mod = applier._load_mutation_module()
    return mut_mod.Mutation(
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.update,
        target=target,
        payload=payload,
        provenance={"source": "test", "jira_key": target},
    )


def _read_events(ticket_dir: Path) -> list[dict]:
    events = []
    for ef in sorted(ticket_dir.glob("*.json")):
        events.append(json.loads(ef.read_text(encoding="utf-8")))
    return events


# ---------------------------------------------------------------------------
# 1. EDIT event written under bound UUID, not jira-dig-* derived from target
# ---------------------------------------------------------------------------


def test_edit_written_under_bound_local_uuid_not_jira_target(tmp_path, applier):
    """When payload.local_id is a UUID (bound ticket), the EDIT event is
    written under <tracker>/<uuid>/, not <tracker>/jira-dig-9999/."""
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    local_uuid = "abcd1234-5678-9012-3456-7890abcdef00"

    # Pre-create the bound ticket directory so the test is realistic.
    (tracker_dir / local_uuid).mkdir()

    mutation = _make_mutation(
        applier,
        target="DIG-9999",
        payload={
            "local_id": local_uuid,
            "fields": {
                "title": "Updated title",
                "description": "Updated body",
                "priority": 1,
                "ticket_type": "task",
            },
        },
    )

    applier._apply_inbound_update(mutation, client=None, repo_root=tmp_path)

    # Affirmative: events landed under the bound UUID dir.
    bound_events = _read_events(tracker_dir / local_uuid)
    assert bound_events, (
        f"Expected EDIT event under bound UUID dir {local_uuid}, found none. "
        f"Tracker contents: {sorted(p.name for p in tracker_dir.iterdir())}"
    )
    edit_events = [e for e in bound_events if e.get("event_type") == "EDIT"]
    assert len(edit_events) == 1, (
        f"Expected exactly 1 EDIT event under bound UUID dir, got "
        f"{[e.get('event_type') for e in bound_events]}"
    )

    # Negative: the Jira-key-derived dir was NOT created (the duplicate-
    # ticket / silent-data-loss symptom).
    jira_derived = tracker_dir / "jira-dig-9999"
    assert not jira_derived.exists(), (
        f"_apply_inbound_update wrote to jira-key-derived dir {jira_derived} "
        "instead of the bound UUID — this is the duplicate-ticket bug."
    )


# ---------------------------------------------------------------------------
# 2. Differ-emitted local field keys are honoured
# ---------------------------------------------------------------------------


def test_edit_fields_use_local_keyed_shape_from_differ(tmp_path, applier):
    """The inbound differ emits ``title`` (not ``summary``) and ``ticket_type``.
    The applier must write both into the EDIT event."""
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    local_uuid = "11111111-2222-3333-4444-555555555555"
    (tracker_dir / local_uuid).mkdir()

    mutation = _make_mutation(
        applier,
        target="DIG-1001",
        payload={
            "local_id": local_uuid,
            "fields": {
                "title": "X",
                "description": "Y",
                "priority": 1,
                "ticket_type": "story",
            },
        },
    )

    applier._apply_inbound_update(mutation, client=None, repo_root=tmp_path)

    events = _read_events(tracker_dir / local_uuid)
    edit = next(e for e in events if e.get("event_type") == "EDIT")
    fields = edit["data"]["fields"]
    assert fields.get("title") == "X", (
        f"Expected title='X' in EDIT data.fields, got {fields}"
    )
    assert fields.get("description") == "Y"
    assert fields.get("priority") == 1
    assert fields.get("ticket_type") == "story", (
        f"Expected ticket_type='story' (differ-emitted local key) to be "
        f"forwarded, got {fields}"
    )


def test_legacy_summary_key_still_accepted_for_backcompat(tmp_path, applier):
    """A legacy caller passing the Jira-keyed ``summary`` (not ``title``) must
    still produce an EDIT with ``title`` set — back-compat for callers that
    bypass the differ."""
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    local_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    (tracker_dir / local_uuid).mkdir()

    mutation = _make_mutation(
        applier,
        target="DIG-1002",
        payload={
            "local_id": local_uuid,
            "fields": {"summary": "Legacy summary"},
        },
    )

    applier._apply_inbound_update(mutation, client=None, repo_root=tmp_path)

    events = _read_events(tracker_dir / local_uuid)
    edit = next(e for e in events if e.get("event_type") == "EDIT")
    assert edit["data"]["fields"].get("title") == "Legacy summary"


# ---------------------------------------------------------------------------
# 3. ADF description is normalized to plain text
# ---------------------------------------------------------------------------


def test_adf_description_dict_normalized_to_plain_text(tmp_path, applier):
    """A description supplied as an ADF dict must be written as plain text."""
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    local_uuid = "12121212-3434-5656-7878-909090909090"
    (tracker_dir / local_uuid).mkdir()

    adf = {
        "type": "doc",
        "content": [
            {
                "type": "paragraph",
                "content": [{"type": "text", "text": "hello"}],
            }
        ],
    }

    mutation = _make_mutation(
        applier,
        target="DIG-1003",
        payload={
            "local_id": local_uuid,
            "fields": {"description": adf},
        },
    )

    applier._apply_inbound_update(mutation, client=None, repo_root=tmp_path)

    events = _read_events(tracker_dir / local_uuid)
    edit = next(e for e in events if e.get("event_type") == "EDIT")
    desc = edit["data"]["fields"].get("description")
    assert isinstance(desc, str), (
        f"Expected description normalized to str, got {type(desc).__name__}: {desc!r}"
    )
    assert "hello" in desc, f"Expected normalized text to contain 'hello', got {desc!r}"


# ---------------------------------------------------------------------------
# 4. Local-mapped status is NOT double-mapped
# ---------------------------------------------------------------------------


def test_status_already_local_not_double_mapped(tmp_path, applier):
    """When the differ supplies status='in_progress' (already local-mapped),
    the applier must write that exact value — not re-run it through
    _jira_status_to_local (which would turn it into '' / garbage)."""
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    local_uuid = "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb"
    (tracker_dir / local_uuid).mkdir()

    mutation = _make_mutation(
        applier,
        target="DIG-1004",
        payload={
            "local_id": local_uuid,
            "fields": {"status": "in_progress"},
        },
    )

    applier._apply_inbound_update(mutation, client=None, repo_root=tmp_path)

    events = _read_events(tracker_dir / local_uuid)
    status_events = [e for e in events if e.get("event_type") == "STATUS"]
    assert len(status_events) == 1, (
        f"Expected 1 STATUS event, got {[e.get('event_type') for e in events]}"
    )
    assert status_events[0]["data"].get("status") == "in_progress", (
        f"Expected status='in_progress' (no double-map), got {status_events[0]['data']}"
    )

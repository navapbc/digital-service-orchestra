"""Tests verifying that _handle_edit.py preserves local bug-type-* tags
when Jira inbound sync sends labels that omit them.

The preservation logic does NOT exist yet — these tests are written RED (failing)
as part of task b34c-0b30-835e-448c.

Test: python3 -m pytest tests/scripts/test_handle_edit_tag_preservation.py -v
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock

import pytest

# ---------------------------------------------------------------------------
# Module loading — import _handle_edit directly so we can call handle_edit()
# ---------------------------------------------------------------------------

_BRIDGE_DIR = (
    Path(__file__).resolve().parents[2] / "plugins" / "dso" / "scripts" / "bridge"
)
_TICKET_REDUCER_DIR = (
    Path(__file__).resolve().parents[2] / "plugins" / "dso" / "scripts"
)


def _load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def handle_edit_mod() -> ModuleType:
    """Load the _handle_edit module directly."""
    path = _BRIDGE_DIR / "_handle_edit.py"
    if not path.exists():
        pytest.fail(f"_handle_edit.py not found at {path}")
    # Ensure bridge package is importable
    bridge_scripts = str(_BRIDGE_DIR.parent)
    if bridge_scripts not in sys.path:
        sys.path.insert(0, bridge_scripts)
    return _load_module("_handle_edit", path)


# ---------------------------------------------------------------------------
# Helper: build a minimal ticket_reducer mock given a local tag list
# ---------------------------------------------------------------------------


def _make_reducer(
    local_tags: list[str],
    *,
    title: str = "Test Ticket",
    priority: int = 2,
    assignee: str = "Alice",
    description: str = "A test description",
) -> MagicMock:
    """Return a mock ticket_reducer whose reduce_ticket() returns state with given tags."""
    mock_reducer = MagicMock()
    mock_reducer.reduce_ticket.return_value = {
        "title": title,
        "priority": priority,
        "assignee": assignee,
        "description": description,
        "tags": local_tags,
        "status": "open",
        "ticket_type": "bug",
        "parent_id": None,
    }
    return mock_reducer


def _collect_edit_fields(captured_calls: list[dict]) -> dict:
    """Return the 'fields' dict from the first write_edit_event call, or {} if none."""
    if not captured_calls:
        return {}
    return captured_calls[0].get("fields", {})


class TestBugTypeTagPreservation:
    """_handle_edit must preserve local bug-type-* tags when Jira inbound drops them.

    The preservation logic is NOT yet implemented — every test in this class
    is expected to FAIL until the feature is added.
    """

    def _run_handle_edit(
        self,
        handle_edit_mod: ModuleType,
        tmp_path: Path,
        jira_key: str,
        jira_labels: list[str],
        local_tags: list[str],
    ) -> list[dict]:
        """Run handle_edit and return list of write_edit_event kwarg dicts."""
        tracker = tmp_path / ".tickets-tracker"
        local_id = f"jira-{jira_key.lower()}"
        ticket_dir = tracker / local_id
        ticket_dir.mkdir(parents=True)

        mock_reducer = _make_reducer(local_tags)

        captured: list[dict] = []

        def fake_write_edit_event(
            *,
            ticket_id: str,
            fields: dict,
            ticket_dir: Path,
            bridge_env_id: str,
            run_id: str = "",
        ) -> None:
            captured.append({"ticket_id": ticket_id, "fields": fields})

        handle_edit_mod.handle_edit(
            issue={
                "key": jira_key,
                "fields": {
                    "summary": "Test Ticket",
                    "description": "A test description",
                    "priority": {"name": "Medium"},
                    "assignee": {"displayName": "Alice"},
                    "labels": jira_labels,
                },
            },
            tickets_root=tracker,
            bridge_env_id="bbbbbbbb-0000-4000-8000-000000000002",
            run_id="test-run",
            ticket_reducer=mock_reducer,
            write_edit_event_fn=fake_write_edit_event,
        )

        return captured

    def test_scenario1_bug_type_tag_stripped_by_jira_is_preserved(
        self, handle_edit_mod: ModuleType, tmp_path: Path
    ) -> None:
        """Scenario 1: Jira drops bug-type-scope-drift from labels.

        Local has ['bug-type-scope-drift', 'review:complete'].
        Jira sends ['review:complete'] — the bug-type tag is absent.

        The idempotency fix means merged == local, so no tags EDIT is written at all.
        Preservation is passive: by skipping the EDIT, the local bug-type tag stays intact.
        No EDIT event should write a tags field that excludes 'bug-type-scope-drift'.
        """
        local_tags = ["bug-type-scope-drift", "review:complete"]
        jira_labels = ["review:complete"]

        captured = self._run_handle_edit(
            handle_edit_mod,
            tmp_path,
            jira_key="DSO-BTAG-1",
            jira_labels=jira_labels,
            local_tags=local_tags,
        )

        # merged == local → no tags EDIT written; bug-type is passively preserved.
        tags_edits = [c for c in captured if "tags" in c["fields"]]
        assert len(tags_edits) == 0, (
            "No tags EDIT event should be written when merged tags equal local tags. "
            f"Got: {tags_edits}"
        )

    def test_scenario2_bug_type_tag_plus_new_jira_label(
        self, handle_edit_mod: ModuleType, tmp_path: Path
    ) -> None:
        """Scenario 2: Jira sends a new label; local has a bug-type tag Jira doesn't know about.

        Local has ['bug-type-scope-drift'].
        Jira sends ['new-jira-label'].
        Expected: edit_fields['tags'] includes BOTH 'bug-type-scope-drift' AND 'new-jira-label'.

        This test FAILS until preservation logic is implemented.
        """
        local_tags = ["bug-type-scope-drift"]
        jira_labels = ["new-jira-label"]

        captured = self._run_handle_edit(
            handle_edit_mod,
            tmp_path,
            jira_key="DSO-BTAG-2",
            jira_labels=jira_labels,
            local_tags=local_tags,
        )

        assert len(captured) >= 1, (
            "Expected write_edit_event to be called when Jira tags differ from local"
        )
        tags_written = captured[0]["fields"].get("tags", [])
        assert "bug-type-scope-drift" in tags_written, (
            f"bug-type-scope-drift must be preserved alongside new Jira label. Got: {tags_written}"
        )
        assert "new-jira-label" in tags_written, (
            f"new-jira-label from Jira must be included. Got: {tags_written}"
        )

    def test_scenario3_no_bug_type_tags_normal_overwrite(
        self, handle_edit_mod: ModuleType, tmp_path: Path
    ) -> None:
        """Scenario 3: No bug-type tags locally — normal overwrite behavior applies.

        Local has ['review:complete'].
        Jira sends ['different-label'].
        Expected: edit_fields['tags'] contains 'different-label' (normal overwrite).

        This test should PASS already (it tests existing behavior, not the new feature),
        but is included as a regression guard.
        """
        local_tags = ["review:complete"]
        jira_labels = ["different-label"]

        captured = self._run_handle_edit(
            handle_edit_mod,
            tmp_path,
            jira_key="DSO-BTAG-3",
            jira_labels=jira_labels,
            local_tags=local_tags,
        )

        assert len(captured) >= 1, (
            "Expected write_edit_event to be called when Jira labels differ from local"
        )
        tags_written = captured[0]["fields"].get("tags", [])
        assert "different-label" in tags_written, (
            f"Jira label must appear in written tags. Got: {tags_written}"
        )

    def test_scenario4_empty_jira_labels_existing_safeguard(
        self, handle_edit_mod: ModuleType, tmp_path: Path
    ) -> None:
        """Scenario 4: Empty Jira labels — existing safeguard must not write tags field.

        Local has ['bug-type-scope-drift'].
        Jira sends [] (empty).
        Expected: 'tags' NOT in edit_fields (existing safeguard: don't overwrite
        when Jira sends empty labels).

        This test PASSES with existing behavior (empty-labels safeguard already exists).
        Included to ensure preservation logic doesn't accidentally break the safeguard.
        """
        local_tags = ["bug-type-scope-drift"]
        jira_labels = []

        captured = self._run_handle_edit(
            handle_edit_mod,
            tmp_path,
            jira_key="DSO-BTAG-4",
            jira_labels=jira_labels,
            local_tags=local_tags,
        )

        # Either no EDIT event was written, or if one was written (for other fields),
        # 'tags' must not appear in it.
        for call in captured:
            assert "tags" not in call["fields"], (
                f"Empty Jira labels must not produce an EDIT(tags) event. "
                f"Got fields: {call['fields']}"
            )

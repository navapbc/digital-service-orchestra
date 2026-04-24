"""Outbound field-coverage tests for the Jira bridge (Local -> Jira).

Systematically verifies which fields and values successfully sync from
local tickets to Jira using mocked ACLI clients.

Fields under test:
  - title/summary
  - description
  - priority
  - assignee
  - status (multiple values)
  - ticket_type/issuetype
  - comments
  - EDIT events (field updates)

Test: python3 -m pytest tests/scripts/test_bridge_outbound_field_coverage.py -v
"""

from __future__ import annotations

from pathlib import Path
from types import ModuleType
from typing import Any
from unittest.mock import MagicMock

import pytest

from bridge_test_helpers import (
    BRIDGE_ENV_ID,
    JIRA_KEY,
    make_create_event,
    write_event,
    write_sync,
)


class TestOutboundTitle:
    """Test whether ticket title is sent to Jira on CREATE."""

    def test_create_sends_title_to_jira(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """CREATE event should send title to Jira via create_issue."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-t001"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        create_path = make_create_event(
            ticket_dir, title="My Important Bug", ticket_type="bug"
        )

        mock_acli = MagicMock()
        mock_acli.create_issue.return_value = {"key": "DSO-1"}

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "CREATE",
                "file_path": str(create_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        mock_acli.create_issue.assert_called_once()
        call_data = mock_acli.create_issue.call_args[0][0]
        assert call_data.get("title") == "My Important Bug", (
            f"OUTBOUND CREATE should send title to Jira. Got: {call_data}"
        )


class TestOutboundDescription:
    """Test whether ticket description is sent to Jira on CREATE."""

    def test_create_sends_description_to_jira(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """CREATE event should send description to Jira."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-d001"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        create_path = make_create_event(
            ticket_dir, title="Desc Test", description="Detailed bug description"
        )

        mock_acli = MagicMock()
        mock_acli.create_issue.return_value = {"key": "DSO-2"}

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "CREATE",
                "file_path": str(create_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        mock_acli.create_issue.assert_called_once()
        call_data = mock_acli.create_issue.call_args[0][0]
        assert (
            "description" in call_data
            and call_data["description"] == "Detailed bug description"
        ), f"OUTBOUND CREATE should send description to Jira. Got: {call_data}"


class TestOutboundPriority:
    """Test whether ticket priority is sent to Jira on CREATE."""

    @pytest.mark.parametrize("priority", [0, 1, 2, 3, 4])
    def test_create_sends_priority_to_jira(
        self, outbound: ModuleType, tmp_path: Path, priority: int
    ) -> None:
        """CREATE event should send priority to Jira for each priority level."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = f"test-p{priority:03d}"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        create_path = make_create_event(
            ticket_dir, title=f"Priority {priority} Bug", priority=priority
        )

        mock_acli = MagicMock()
        mock_acli.create_issue.return_value = {"key": f"DSO-P{priority}"}

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "CREATE",
                "file_path": str(create_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        mock_acli.create_issue.assert_called_once()
        call_data = mock_acli.create_issue.call_args[0][0]
        assert "priority" in call_data, (
            f"OUTBOUND CREATE should include priority field. Got: {call_data}"
        )
        assert call_data["priority"] == priority, (
            f"OUTBOUND CREATE should send priority={priority}. Got: {call_data.get('priority')}"
        )


class TestOutboundAssignee:
    """Test whether ticket assignee is sent to Jira on CREATE."""

    def test_create_sends_assignee_to_jira(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """CREATE event should send assignee to Jira."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-a001"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        create_path = make_create_event(
            ticket_dir, title="Assignee Test", assignee="alice"
        )

        mock_acli = MagicMock()
        mock_acli.create_issue.return_value = {"key": "DSO-A1"}

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "CREATE",
                "file_path": str(create_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        mock_acli.create_issue.assert_called_once()
        call_data = mock_acli.create_issue.call_args[0][0]
        assert "assignee" in call_data and call_data["assignee"] == "alice", (
            f"OUTBOUND CREATE should send assignee to Jira. Got: {call_data}"
        )


class TestOutboundStatus:
    """Test whether status transitions are sent to Jira."""

    @pytest.mark.parametrize(
        "status",
        ["open", "in_progress", "closed"],
    )
    def test_status_event_pushes_to_jira(
        self, outbound: ModuleType, tmp_path: Path, status: str
    ) -> None:
        """STATUS event should push compiled status to Jira for each status value."""
        from unittest.mock import patch

        import bridge._outbound_handlers as _outbound_handlers_mod

        tracker = tmp_path / ".tickets-tracker"
        ticket_id = f"test-s-{status}"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        # Write a CREATE event first (so the reducer can compile state)
        make_create_event(ticket_dir, title="Status Test")
        # Write a SYNC event so outbound knows the Jira key
        write_sync(ticket_dir, JIRA_KEY)
        # Write the STATUS event
        write_event(ticket_dir, "STATUS", {"status": status})

        # Build the event for process_outbound
        status_files = sorted(ticket_dir.glob("*-STATUS.json"))
        assert status_files, "STATUS event file should exist"

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "STATUS",
                "file_path": str(status_files[0]),
            }
        ]

        # Mock get_compiled_status to avoid dependency on real ticket-reducer.py
        with patch.object(
            _outbound_handlers_mod, "get_compiled_status", return_value=status
        ):
            outbound.process_outbound(
                events,
                acli_client=mock_acli,
                tickets_root=tracker,
                bridge_env_id=BRIDGE_ENV_ID,
            )

        mock_acli.update_issue.assert_called_once()
        call_args = mock_acli.update_issue.call_args
        assert call_args[0][0] == JIRA_KEY, "Should update the correct Jira key"
        assert call_args[1].get("status") == status, (
            f"OUTBOUND STATUS should push status='{status}' to Jira. Got: {call_args}"
        )


class TestOutboundTicketType:
    """Test whether ticket_type is sent to Jira on CREATE."""

    @pytest.mark.parametrize("ticket_type", ["bug", "story", "task", "epic"])
    def test_create_sends_type_to_jira(
        self, outbound: ModuleType, tmp_path: Path, ticket_type: str
    ) -> None:
        """CREATE event should send ticket_type to Jira."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = f"test-type-{ticket_type}"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        create_path = make_create_event(
            ticket_dir, title=f"Type {ticket_type}", ticket_type=ticket_type
        )

        mock_acli = MagicMock()
        mock_acli.create_issue.return_value = {"key": f"DSO-T{ticket_type[0].upper()}"}

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "CREATE",
                "file_path": str(create_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        mock_acli.create_issue.assert_called_once()
        call_data = mock_acli.create_issue.call_args[0][0]
        assert "ticket_type" in call_data, (
            f"OUTBOUND CREATE should include ticket_type. Got: {call_data}"
        )


class TestOutboundComment:
    """Test whether comments are sent to Jira."""

    def test_comment_event_pushes_to_jira(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """COMMENT event should push comment body to Jira."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-c001"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="Comment Test")
        write_sync(ticket_dir, JIRA_KEY)

        comment_path = write_event(
            ticket_dir,
            "COMMENT",
            {"body": "This is a test comment"},
        )

        mock_acli = MagicMock()
        mock_acli.add_comment.return_value = {"id": "10001"}

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "COMMENT",
                "file_path": str(comment_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        mock_acli.add_comment.assert_called_once()
        call_args = mock_acli.add_comment.call_args
        assert call_args[0][0] == JIRA_KEY
        assert "This is a test comment" in call_args[0][1], (
            f"OUTBOUND COMMENT should include comment body. Got: {call_args}"
        )


class TestOutboundEditFields:
    """Test whether EDIT events (field updates) are synced to Jira.

    EDIT events update fields post-creation. This tests whether
    the outbound bridge processes EDIT events at all.
    """

    # REVIEW-DEFENSE: strict=True with parametrize is intentional here.
    # Each parametrized case independently tests a separate field (title,
    # priority, assignee).  All three fail identically because
    # bridge-outbound.py has zero EDIT event handling — process_outbound()
    # only handles CREATE, STATUS, and COMMENT events.  strict=True is the
    # correct choice because:
    #   1. If ANY single field starts passing unexpectedly (e.g., partial EDIT
    #      support is added for title but not priority), we WANT the XPASS
    #      failure to surface immediately so the test can be updated to reflect
    #      the new reality.
    #   2. Without strict=True, silently passing cases would hide real
    #      implementation changes from the test suite.
    @pytest.mark.parametrize(
        "field,value,expected_jira_field,expected_jira_value",
        [
            # title maps to "summary" in Jira
            ("title", "Updated Title", "summary", "Updated Title"),
            ("priority", 0, "priority", "Highest"),
            ("assignee", "bob", "assignee", "bob"),
            # ticket_type maps to "type" in Jira (capitalized)
            ("ticket_type", "story", "type", "Story"),
        ],
    )
    def test_edit_event_pushes_field_to_jira(
        self,
        outbound: ModuleType,
        tmp_path: Path,
        field: str,
        value: Any,
        expected_jira_field: str,
        expected_jira_value: str,
    ) -> None:
        """EDIT event should push field updates to Jira."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = f"test-edit-{field}"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="Edit Test")
        write_sync(ticket_dir, JIRA_KEY)

        edit_path = write_event(
            ticket_dir,
            "EDIT",
            {"fields": {field: value}},
        )

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "EDIT",
                "file_path": str(edit_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert mock_acli.update_issue.called, (
            f"OUTBOUND EDIT should trigger update_issue for field '{field}'."
        )
        call_args = mock_acli.update_issue.call_args
        call_kwargs = call_args[1] if call_args[1] else {}
        assert expected_jira_field in call_kwargs, (
            f"OUTBOUND EDIT should send '{expected_jira_field}' to Jira. "
            f"Got kwargs: {call_kwargs}"
        )
        assert call_kwargs[expected_jira_field] == expected_jira_value, (
            f"OUTBOUND EDIT should send {expected_jira_field}='{expected_jira_value}'. "
            f"Got: {call_kwargs[expected_jira_field]!r}"
        )


# ===========================================================================
# FIELD COVERAGE SUMMARY TEST
# ===========================================================================


class TestFieldCoverageSummary:
    """Meta-test that summarizes which fields the outbound bridge actually passes through.

    This test inspects what the outbound bridge's CREATE handler extracts from
    the event data and passes to acli_client.create_issue(). It confirms the
    exact set of fields that are forwarded.
    """

    def test_outbound_create_passes_full_ticket_data(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """Capture exactly which fields from a CREATE event reach acli_client.create_issue()."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-full"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        create_path = make_create_event(
            ticket_dir,
            title="Full Field Test",
            ticket_type="story",
            priority=1,
            assignee="charlie",
            description="Full description here",
        )

        captured: list[dict[str, Any]] = []

        def mock_create(data: dict[str, Any]) -> dict[str, Any]:
            captured.append(data)
            return {"key": "DSO-FULL"}

        mock_acli = MagicMock()
        mock_acli.create_issue.side_effect = mock_create

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "CREATE",
                "file_path": str(create_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert len(captured) == 1, "create_issue should be called exactly once"
        received = captured[0]

        # Report which fields were received vs expected
        expected_fields = {
            "title",
            "ticket_type",
            "priority",
            "assignee",
            "description",
        }
        received_fields = set(received.keys())
        missing = expected_fields - received_fields
        present = expected_fields & received_fields

        # This assertion will show exactly which fields are missing
        assert not missing, (
            f"OUTBOUND CREATE field coverage gap:\n"
            f"  Fields PRESENT in Jira call: {sorted(present)}\n"
            f"  Fields MISSING from Jira call: {sorted(missing)}\n"
            f"  Full data passed to create_issue: {received}"
        )


# ===========================================================================
# EMPTY DESCRIPTION SAFEGUARD TESTS
# ===========================================================================


class TestOutboundEmptyDescriptionSafeguard:
    """Verify that empty descriptions never overwrite non-empty ones in Jira."""

    def test_edit_empty_description_is_not_pushed(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """EDIT event with empty description should NOT call update_issue."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-empty-desc"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="Desc Guard Test")
        write_sync(ticket_dir, JIRA_KEY)

        edit_path = write_event(
            ticket_dir,
            "EDIT",
            {"fields": {"description": ""}},
        )

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "EDIT",
                "file_path": str(edit_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        # update_issue should NOT be called — empty description is the only field
        assert not mock_acli.update_issue.called, (
            "OUTBOUND EDIT with empty description should not push to Jira"
        )

    def test_edit_whitespace_description_is_not_pushed(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """EDIT event with whitespace-only description should NOT call update_issue."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-ws-desc"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="WS Desc Test")
        write_sync(ticket_dir, JIRA_KEY)

        edit_path = write_event(
            ticket_dir,
            "EDIT",
            {"fields": {"description": "   \n  "}},
        )

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "EDIT",
                "file_path": str(edit_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert not mock_acli.update_issue.called, (
            "OUTBOUND EDIT with whitespace-only description should not push to Jira"
        )

    def test_edit_nonempty_description_is_pushed(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """EDIT event with non-empty description SHOULD call update_issue."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-good-desc"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="Good Desc Test")
        write_sync(ticket_dir, JIRA_KEY)

        edit_path = write_event(
            ticket_dir,
            "EDIT",
            {"fields": {"description": "Updated description"}},
        )

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "EDIT",
                "file_path": str(edit_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert mock_acli.update_issue.called, (
            "OUTBOUND EDIT with non-empty description should push to Jira"
        )
        call_kwargs = mock_acli.update_issue.call_args[1]
        assert call_kwargs.get("description") == "Updated description"


# ===========================================================================
# EMPTY TITLE SAFEGUARD TESTS (bug eccb-3f26)
# ===========================================================================


class TestOutboundEmptyTitleSafeguard:
    """Verify that empty/whitespace titles never overwrite Jira summary."""

    def test_edit_empty_title_is_not_pushed(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """EDIT event with empty title should NOT call update_issue (eccb-3f26)."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-empty-title"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="Title Guard Test")
        write_sync(ticket_dir, JIRA_KEY)

        edit_path = write_event(
            ticket_dir,
            "EDIT",
            {"fields": {"title": ""}},
        )

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "EDIT",
                "file_path": str(edit_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert not mock_acli.update_issue.called, (
            "OUTBOUND EDIT with empty title should not push empty summary to Jira (eccb-3f26)"
        )

    def test_edit_whitespace_title_is_not_pushed(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """EDIT event with whitespace-only title should NOT call update_issue (eccb-3f26)."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-ws-title"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="WS Title Test")
        write_sync(ticket_dir, JIRA_KEY)

        edit_path = write_event(
            ticket_dir,
            "EDIT",
            {"fields": {"title": "   \n  "}},
        )

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "EDIT",
                "file_path": str(edit_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert not mock_acli.update_issue.called, (
            "OUTBOUND EDIT with whitespace-only title should not push to Jira (eccb-3f26)"
        )

    def test_edit_nonempty_title_is_pushed(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """EDIT event with non-empty title SHOULD call update_issue with summary."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-good-title"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="Good Title Test")
        write_sync(ticket_dir, JIRA_KEY)

        edit_path = write_event(
            ticket_dir,
            "EDIT",
            {"fields": {"title": "Updated Title"}},
        )

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "EDIT",
                "file_path": str(edit_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert mock_acli.update_issue.called, (
            "OUTBOUND EDIT with non-empty title should push to Jira"
        )
        call_kwargs = mock_acli.update_issue.call_args[1]
        assert call_kwargs.get("summary") == "Updated Title"


# ===========================================================================
# INVALID ASSIGNEE SAFEGUARD TESTS (bug 277e-d926)
# ===========================================================================


class TestOutboundInvalidAssigneeSafeguard:
    """Verify that empty/whitespace assignees are not pushed to Jira."""

    def test_edit_empty_assignee_is_not_pushed(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """EDIT event with empty assignee should NOT call update_issue (277e-d926)."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-empty-assignee"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="Assignee Guard Test")
        write_sync(ticket_dir, JIRA_KEY)

        edit_path = write_event(
            ticket_dir,
            "EDIT",
            {"fields": {"assignee": ""}},
        )

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "EDIT",
                "file_path": str(edit_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert not mock_acli.update_issue.called, (
            "OUTBOUND EDIT with empty assignee should not push to Jira (277e-d926)"
        )

    def test_edit_whitespace_assignee_is_not_pushed(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """EDIT event with whitespace-only assignee should NOT call update_issue (277e-d926)."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-ws-assignee"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="WS Assignee Test")
        write_sync(ticket_dir, JIRA_KEY)

        edit_path = write_event(
            ticket_dir,
            "EDIT",
            {"fields": {"assignee": "   "}},
        )

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "EDIT",
                "file_path": str(edit_path),
            }
        ]

        outbound.process_outbound(
            events,
            acli_client=mock_acli,
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert not mock_acli.update_issue.called, (
            "OUTBOUND EDIT with whitespace-only assignee should not push to Jira (277e-d926)"
        )


# ===========================================================================
# STATUS HANDLER NULL COMPILED STATUS TESTS (bug c22b-a25b)
# ===========================================================================


class TestOutboundStatusNullCompiledStatus:
    """Verify that a STATUS event with no compiled status emits a BRIDGE_ALERT."""

    def test_status_null_compiled_status_writes_bridge_alert(
        self, outbound: ModuleType, tmp_path: Path
    ) -> None:
        """STATUS event where get_compiled_status returns None should write a BRIDGE_ALERT (c22b-a25b)."""
        from unittest.mock import patch

        import bridge._outbound_handlers as _outbound_handlers_mod

        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "test-null-status"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        make_create_event(ticket_dir, title="Null Status Test")
        write_sync(ticket_dir, JIRA_KEY)
        write_event(ticket_dir, "STATUS", {"status": "in_progress"})

        status_files = sorted(ticket_dir.glob("*-STATUS.json"))
        assert status_files, "STATUS event file should exist"

        mock_acli = MagicMock()

        events = [
            {
                "ticket_id": ticket_id,
                "event_type": "STATUS",
                "file_path": str(status_files[0]),
            }
        ]

        # Mock get_compiled_status to return None (reducer failure scenario)
        with patch.object(
            _outbound_handlers_mod, "get_compiled_status", return_value=None
        ):
            outbound.process_outbound(
                events,
                acli_client=mock_acli,
                tickets_root=tracker,
                bridge_env_id=BRIDGE_ENV_ID,
            )

        # update_issue should NOT be called when compiled_status is None
        assert not mock_acli.update_issue.called, (
            "OUTBOUND STATUS with null compiled_status should not push to Jira"
        )

        # A BRIDGE_ALERT must be written to notify about the dropped event
        alert_files = list(ticket_dir.glob("*-BRIDGE_ALERT.json"))
        assert len(alert_files) == 1, (
            f"OUTBOUND STATUS with null compiled_status must write exactly 1 BRIDGE_ALERT "
            f"to signal the dropped event (c22b-a25b). Got: {alert_files}"
        )

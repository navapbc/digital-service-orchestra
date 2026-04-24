"""Inbound field-coverage tests for the Jira bridge (Jira -> Local).

Systematically verifies which fields and values successfully sync from
Jira to local tickets using mocked ACLI clients.

Fields under test:
  - title/summary
  - description
  - priority
  - assignee
  - status (multiple values + unmapped alert)
  - ticket_type/issuetype
  - comments

Test: python3 -m pytest tests/scripts/test_bridge_inbound_field_coverage.py -v
"""

from __future__ import annotations

import json
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

import pytest

from bridge_test_helpers import BRIDGE_ENV_ID, make_create_event, write_sync


class TestInboundTitle:
    """Test whether Jira issue summary becomes the local ticket title."""

    def test_create_event_includes_title(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """Inbound CREATE should write the Jira summary as a field."""
        tracker = tmp_path / ".tickets-tracker"
        tracker.mkdir(parents=True)

        issues = [
            {
                "key": "DSO-200",
                "fields": {
                    "summary": "Bug from Jira",
                    "issuetype": {"name": "Bug"},
                    "status": {"name": "Open"},
                    "created": "2026-03-20T10:00:00.000+0000",
                    "updated": "2026-03-20T10:00:00.000+0000",
                },
            }
        ]

        paths = inbound.write_create_events(
            issues,
            tickets_tracker=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert len(paths) == 1
        event_data = json.loads(paths[0].read_text(encoding="utf-8"))
        fields = event_data.get("data", {}).get("fields", {})
        assert "summary" in fields, (
            f"INBOUND CREATE should include summary/title. Got fields: {list(fields.keys())}"
        )
        assert fields["summary"] == "Bug from Jira"


class TestInboundDescription:
    """Test whether Jira issue description is synced inbound."""

    def test_create_event_includes_description(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """Inbound CREATE should include the Jira description field."""
        tracker = tmp_path / ".tickets-tracker"
        tracker.mkdir(parents=True)

        issues = [
            {
                "key": "DSO-201",
                "fields": {
                    "summary": "Desc Inbound Test",
                    "description": "This is the Jira description",
                    "issuetype": {"name": "Bug"},
                    "status": {"name": "Open"},
                    "created": "2026-03-20T10:00:00.000+0000",
                    "updated": "2026-03-20T10:00:00.000+0000",
                },
            }
        ]

        paths = inbound.write_create_events(
            issues,
            tickets_tracker=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert len(paths) == 1
        event_data = json.loads(paths[0].read_text(encoding="utf-8"))
        fields = event_data.get("data", {}).get("fields", {})
        assert "description" in fields, (
            f"INBOUND CREATE should include description. Got fields: {list(fields.keys())}"
        )
        assert fields["description"] == "This is the Jira description"


class TestInboundPriority:
    """Test whether Jira issue priority is synced inbound."""

    @pytest.mark.parametrize(
        "jira_priority_name",
        ["Highest", "High", "Medium", "Low", "Lowest"],
    )
    def test_create_event_includes_priority(
        self, inbound: ModuleType, tmp_path: Path, jira_priority_name: str
    ) -> None:
        """Inbound CREATE should include the Jira priority field."""
        tracker = tmp_path / ".tickets-tracker"
        tracker.mkdir(parents=True)

        issues = [
            {
                "key": f"DSO-PRI-{jira_priority_name[:3].upper()}",
                "fields": {
                    "summary": f"Priority {jira_priority_name}",
                    "priority": {"name": jira_priority_name},
                    "issuetype": {"name": "Bug"},
                    "status": {"name": "Open"},
                    "created": "2026-03-20T10:00:00.000+0000",
                    "updated": "2026-03-20T10:00:00.000+0000",
                },
            }
        ]

        paths = inbound.write_create_events(
            issues,
            tickets_tracker=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert len(paths) == 1
        event_data = json.loads(paths[0].read_text(encoding="utf-8"))
        fields = event_data.get("data", {}).get("fields", {})
        assert "priority" in fields, (
            f"INBOUND CREATE should include priority. Got fields: {list(fields.keys())}"
        )
        assert fields["priority"]["name"] == jira_priority_name


class TestInboundAssignee:
    """Test whether Jira issue assignee is synced inbound."""

    def test_create_event_includes_assignee(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """Inbound CREATE should include the Jira assignee field."""
        tracker = tmp_path / ".tickets-tracker"
        tracker.mkdir(parents=True)

        issues = [
            {
                "key": "DSO-ASN-1",
                "fields": {
                    "summary": "Assignee Inbound Test",
                    "assignee": {
                        "displayName": "Alice",
                        "emailAddress": "alice@example.com",
                    },
                    "issuetype": {"name": "Bug"},
                    "status": {"name": "Open"},
                    "created": "2026-03-20T10:00:00.000+0000",
                    "updated": "2026-03-20T10:00:00.000+0000",
                },
            }
        ]

        paths = inbound.write_create_events(
            issues,
            tickets_tracker=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert len(paths) == 1
        event_data = json.loads(paths[0].read_text(encoding="utf-8"))
        fields = event_data.get("data", {}).get("fields", {})
        assert "assignee" in fields, (
            f"INBOUND CREATE should include assignee. Got fields: {list(fields.keys())}"
        )
        assert fields["assignee"]["displayName"] == "Alice"


class TestInboundStatus:
    """Test whether Jira status changes are synced inbound."""

    @pytest.mark.parametrize(
        "jira_status,local_status",
        [
            ("Open", "open"),
            ("In Progress", "in_progress"),
            ("Done", "closed"),
            ("To Do", "open"),
        ],
    )
    def test_status_change_writes_status_event(
        self, inbound: ModuleType, tmp_path: Path, jira_status: str, local_status: str
    ) -> None:
        """Inbound should write STATUS event when Jira status maps to local status."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = f"jira-dso-st-{jira_status.replace(' ', '').lower()}"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        # Write a SYNC event so the ticket is recognized as existing
        write_sync(ticket_dir, f"DSO-ST-{jira_status.replace(' ', '').upper()}")

        # Simulate the status mapping that process_inbound uses
        status_mapping = {
            "Open": "open",
            "In Progress": "in_progress",
            "Done": "closed",
            "To Do": "open",
        }

        mapped = inbound.map_status(jira_status, mapping=status_mapping)
        assert mapped == local_status, (
            f"map_status('{jira_status}') should return '{local_status}'. Got: {mapped}"
        )

        # Test that write_status_event creates the event file
        event_path = inbound.write_status_event(
            ticket_id=ticket_id,
            status=local_status,
            ticket_dir=ticket_dir,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert event_path.exists()
        event_data = json.loads(event_path.read_text(encoding="utf-8"))
        assert event_data["data"]["status"] == local_status


class TestInboundTicketType:
    """Test whether Jira issue type is synced inbound."""

    @pytest.mark.parametrize(
        "jira_type,local_type",
        [
            ("Bug", "bug"),
            ("Story", "story"),
            ("Task", "task"),
            ("Epic", "epic"),
        ],
    )
    def test_type_mapping(
        self, inbound: ModuleType, tmp_path: Path, jira_type: str, local_type: str
    ) -> None:
        """Inbound should correctly map Jira issue types to local types."""
        type_mapping = {
            "Bug": "bug",
            "Story": "story",
            "Task": "task",
            "Epic": "epic",
        }

        mapped = inbound.map_type(jira_type, mapping=type_mapping)
        assert mapped == local_type, (
            f"map_type('{jira_type}') should return '{local_type}'. Got: {mapped}"
        )


class TestInboundComment:
    """Test whether Jira comments are pulled inbound."""

    def test_pull_comments_writes_comment_events(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """pull_comments should write COMMENT events for new Jira comments."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "jira-dso-cmt-1"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        mock_acli = MagicMock()
        mock_acli.get_comments.return_value = [
            {"id": "50001", "body": "Comment from Jira user"},
            {"id": "50002", "body": "Another Jira comment"},
        ]

        written = inbound.pull_comments(
            jira_key="DSO-CMT-1",
            ticket_id=ticket_id,
            ticket_dir=ticket_dir,
            acli_client=mock_acli,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert len(written) == 2, (
            f"Should write 2 COMMENT events. Wrote: {len(written)}"
        )
        bodies = [e["data"]["body"] for e in written]
        assert "Comment from Jira user" in bodies
        assert "Another Jira comment" in bodies


class TestInboundStatusUnmappedAlert:
    """Test that unmapped Jira statuses trigger BRIDGE_ALERT."""

    def test_unmapped_status_writes_alert(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """Unmapped Jira status should produce a BRIDGE_ALERT event file."""
        tracker = tmp_path / ".tickets-tracker"
        tracker.mkdir(parents=True)

        alert_path = inbound.write_bridge_alert(
            ticket_id="jira-dso-unmapped",
            reason="Unknown status value: 'Weird Status'",
            tickets_root=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert alert_path.exists()
        alert_data = json.loads(alert_path.read_text(encoding="utf-8"))
        assert alert_data["event_type"] == "BRIDGE_ALERT"
        assert "Weird Status" in alert_data["reason"]


class TestInboundEditEventPath:
    """Test that process_inbound writes EDIT events when Jira fields differ from local state."""

    def test_edit_events_for_changed_priority_assignee_title(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """process_inbound should write EDIT events when priority, assignee, and title change."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "jira-dso-edit-1"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        # Create initial ticket state: priority=2, assignee="Alice", title="Original"
        make_create_event(
            ticket_dir,
            title="Original Title",
            ticket_type="bug",
            priority=2,
            assignee="Alice",
            description="Some description",
        )
        write_sync(ticket_dir, "DSO-EDIT-1")

        # Jira issue with changed fields:
        # priority: Medium(2) -> High(1), assignee: Alice -> Bob, title: changed
        jira_issue = {
            "key": "DSO-EDIT-1",
            "fields": {
                "summary": "Updated Title",
                "description": "Some description",
                "priority": {"name": "High"},
                "assignee": {"displayName": "Bob", "emailAddress": "bob@example.com"},
                "issuetype": {"name": "Bug"},
                "status": {"name": "Open"},
                "created": "2026-03-20T10:00:00.000+0000",
                "updated": "2026-03-20T11:00:00.000+0000",
            },
        }

        mock_acli = MagicMock()
        mock_acli.get_myself.return_value = {"timeZone": "UTC"}

        config = {
            "bridge_env_id": BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 15,
            "checkpoint_file": "",
            "status_mapping": {
                "Open": "open",
                "In Progress": "in_progress",
                "Done": "closed",
            },
            "type_mapping": {
                "Bug": "bug",
                "Story": "story",
                "Task": "task",
                "Epic": "epic",
            },
            "run_id": "test-run",
        }

        # Patch fetch_jira_changes to return our crafted issue
        with patch.object(inbound, "fetch_jira_changes", return_value=[jira_issue]):
            inbound.process_inbound(
                tickets_root=tracker,
                acli_client=mock_acli,
                last_pull_ts="2026-03-20T09:00:00Z",
                config=config,
            )

        # Verify EDIT event was written
        edit_files = list(ticket_dir.glob("*-EDIT.json"))
        assert len(edit_files) >= 1, (
            f"Expected at least 1 EDIT event file. Found: {[f.name for f in edit_files]}"
        )

        # Read EDIT event and check fields
        edit_data = json.loads(edit_files[0].read_text(encoding="utf-8"))
        assert edit_data["event_type"] == "EDIT"
        edited_fields = edit_data.get("data", {}).get("fields", {})

        # Priority should change from 2 (Medium) to 1 (High)
        assert "priority" in edited_fields, (
            f"EDIT event should include priority change. Got fields: {list(edited_fields.keys())}"
        )
        assert edited_fields["priority"] == 1

        # Assignee should change from Alice to Bob
        assert "assignee" in edited_fields, (
            f"EDIT event should include assignee change. Got fields: {list(edited_fields.keys())}"
        )
        assert edited_fields["assignee"] == "Bob"

        # Title should change from Original Title to Updated Title
        assert "title" in edited_fields, (
            f"EDIT event should include title change. Got fields: {list(edited_fields.keys())}"
        )
        assert edited_fields["title"] == "Updated Title"

    def test_no_edit_event_when_fields_unchanged(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """process_inbound should NOT write EDIT events when fields match local state."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "jira-dso-edit-2"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        # Create initial ticket with priority=1 (High), assignee="Bob", title="Same"
        make_create_event(
            ticket_dir,
            title="Same Title",
            ticket_type="bug",
            priority=1,
            assignee="Bob",
            description="Unchanged desc",
        )
        write_sync(ticket_dir, "DSO-EDIT-2")

        # Jira issue with same values
        jira_issue = {
            "key": "DSO-EDIT-2",
            "fields": {
                "summary": "Same Title",
                "description": "Unchanged desc",
                "priority": {"name": "High"},
                "assignee": {"displayName": "Bob"},
                "issuetype": {"name": "Bug"},
                "status": {"name": "Open"},
                "created": "2026-03-20T10:00:00.000+0000",
                "updated": "2026-03-20T11:00:00.000+0000",
            },
        }

        mock_acli = MagicMock()
        mock_acli.get_myself.return_value = {"timeZone": "UTC"}

        config = {
            "bridge_env_id": BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 15,
            "checkpoint_file": "",
            "status_mapping": {"Open": "open"},
            "type_mapping": {"Bug": "bug"},
            "run_id": "test-run",
        }

        with patch.object(inbound, "fetch_jira_changes", return_value=[jira_issue]):
            inbound.process_inbound(
                tickets_root=tracker,
                acli_client=mock_acli,
                last_pull_ts="2026-03-20T09:00:00Z",
                config=config,
            )

        # No EDIT events should be written
        edit_files = list(ticket_dir.glob("*-EDIT.json"))
        assert len(edit_files) == 0, (
            f"Expected 0 EDIT events when fields are unchanged. Found: {len(edit_files)}"
        )


# ===========================================================================
# EMPTY DESCRIPTION SAFEGUARD TESTS
# ===========================================================================


class TestInboundEmptyDescriptionSafeguard:
    """Verify that empty Jira descriptions never overwrite non-empty local ones."""

    def test_create_with_empty_description_stores_none(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """Inbound CREATE with empty Jira description should store None, not ''."""
        tracker = tmp_path / ".tickets-tracker"
        tracker.mkdir(parents=True)

        issues = [
            {
                "key": "DSO-EMPTYDESC",
                "fields": {
                    "summary": "No description issue",
                    "description": "",
                    "issuetype": {"name": "Bug"},
                    "status": {"name": "Open"},
                    "created": "2026-03-20T10:00:00.000+0000",
                    "updated": "2026-03-20T10:00:00.000+0000",
                },
            }
        ]

        paths = inbound.write_create_events(
            issues,
            tickets_tracker=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert len(paths) == 1
        event_data = json.loads(paths[0].read_text(encoding="utf-8"))
        data = event_data.get("data", {})
        assert data.get("description") is None, (
            f"Empty Jira description should be stored as None, not {data.get('description')!r}"
        )

    def test_create_with_whitespace_description_stores_none(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """Inbound CREATE with whitespace-only Jira description should store None."""
        tracker = tmp_path / ".tickets-tracker"
        tracker.mkdir(parents=True)

        issues = [
            {
                "key": "DSO-WSDESC",
                "fields": {
                    "summary": "Whitespace description",
                    "description": "   \n  ",
                    "issuetype": {"name": "Bug"},
                    "status": {"name": "Open"},
                    "created": "2026-03-20T10:00:00.000+0000",
                    "updated": "2026-03-20T10:00:00.000+0000",
                },
            }
        ]

        paths = inbound.write_create_events(
            issues,
            tickets_tracker=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert len(paths) == 1
        event_data = json.loads(paths[0].read_text(encoding="utf-8"))
        data = event_data.get("data", {})
        assert data.get("description") is None, (
            f"Whitespace Jira description should be stored as None, not {data.get('description')!r}"
        )

    def test_create_with_nonempty_description_is_stored(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """Inbound CREATE with non-empty description should store it normally."""
        tracker = tmp_path / ".tickets-tracker"
        tracker.mkdir(parents=True)

        issues = [
            {
                "key": "DSO-GOODDESC",
                "fields": {
                    "summary": "Has description",
                    "description": "This is a real description",
                    "issuetype": {"name": "Bug"},
                    "status": {"name": "Open"},
                    "created": "2026-03-20T10:00:00.000+0000",
                    "updated": "2026-03-20T10:00:00.000+0000",
                },
            }
        ]

        paths = inbound.write_create_events(
            issues,
            tickets_tracker=tracker,
            bridge_env_id=BRIDGE_ENV_ID,
        )

        assert len(paths) == 1
        event_data = json.loads(paths[0].read_text(encoding="utf-8"))
        data = event_data.get("data", {})
        assert data.get("description") == "This is a real description"

    def test_edit_empty_description_not_propagated(
        self, inbound: ModuleType, tmp_path: Path
    ) -> None:
        """Inbound EDIT should not overwrite local description with empty Jira value."""
        tracker = tmp_path / ".tickets-tracker"
        ticket_id = "jira-dso-noblank"
        ticket_dir = tracker / ticket_id
        ticket_dir.mkdir(parents=True)

        # Create a ticket with a non-empty description
        make_create_event(
            ticket_dir, title="Has Desc", description="Original description"
        )
        write_sync(ticket_dir, "DSO-NOBLANK")

        mock_acli = MagicMock()
        mock_acli.search_issues.return_value = []
        mock_acli.get_myself.return_value = {"timeZone": "UTC"}

        # Jira issue has empty description
        jira_issue = {
            "key": "DSO-NOBLANK",
            "fields": {
                "summary": "Has Desc",
                "description": "",
                "issuetype": {"name": "Bug"},
                "status": {"name": "Open"},
                "priority": {"name": "Medium"},
                "assignee": None,
                "created": "2026-03-20T10:00:00.000+0000",
                "updated": "2026-03-21T10:00:00.000+0000",
            },
        }

        config = {
            "bridge_env_id": BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 15,
            "status_mapping": {"Open": "open"},
            "type_mapping": {"Bug": "bug"},
            "checkpoint_file": "",
            "run_id": "test-run",
        }

        with patch.object(inbound, "fetch_jira_changes", return_value=[jira_issue]):
            inbound.process_inbound(
                tickets_root=tracker,
                acli_client=mock_acli,
                last_pull_ts="2026-03-20T09:00:00Z",
                config=config,
            )

        # Check that no EDIT event was written for description
        edit_files = list(ticket_dir.glob("*-EDIT.json"))
        for ef in edit_files:
            edata = json.loads(ef.read_text(encoding="utf-8"))
            edited_fields = edata.get("data", {}).get("fields", {})
            assert "description" not in edited_fields, (
                f"Empty Jira description should NOT be synced inbound. "
                f"EDIT event has: {edited_fields}"
            )

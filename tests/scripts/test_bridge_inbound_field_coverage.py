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
from unittest.mock import MagicMock

import pytest

from bridge_test_helpers import BRIDGE_ENV_ID, write_sync


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

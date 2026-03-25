"""ACLI client field-extraction tests for the Jira bridge.

Verifies which fields AcliClient.create_issue() and AcliClient.update_issue()
actually send to the ACLI subprocess. The bridge passes the full data dict,
but AcliClient may only extract a subset of those fields for the ACLI command.

Test: python3 -m pytest tests/scripts/test_bridge_acli_field_coverage.py -v
"""

from __future__ import annotations

from typing import Any
from unittest.mock import patch

import pytest


class TestAcliClientCreateFieldExtraction:
    """Test which fields AcliClient.create_issue() actually sends to the ACLI subprocess.

    The bridge passes the full ticket data dict to acli_client.create_issue(),
    but AcliClient.create_issue() may only extract a subset of those fields
    for the ACLI command. These tests reveal what actually reaches Jira.
    """

    def test_acli_create_sends_summary(self, acli_mod: Any, acli_capture: Any) -> None:
        """AcliClient.create_issue() should send the title/summary to ACLI."""
        client, captured_cmds, fake_run_acli = acli_capture

        ticket_data = {
            "ticket_type": "bug",
            "title": "Test Summary",
            "priority": 1,
            "assignee": "alice",
            "description": "Test description",
        }

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            try:
                client.create_issue(ticket_data)
            except (KeyError, AttributeError):
                pass  # May fail on verify-after-create; we only care about the first call

        assert len(captured_cmds) >= 1, "At least one ACLI command should be issued"
        create_cmd = captured_cmds[0]
        assert "--summary" in create_cmd, (
            f"ACLI create command should include --summary. Got: {create_cmd}"
        )
        summary_idx = create_cmd.index("--summary")
        assert create_cmd[summary_idx + 1] == "Test Summary"

    def test_acli_create_sends_type(self, acli_mod: Any, acli_capture: Any) -> None:
        """AcliClient.create_issue() should send the ticket type to ACLI."""
        client, captured_cmds, fake_run_acli = acli_capture

        ticket_data = {
            "ticket_type": "bug",
            "title": "Test",
        }

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            try:
                client.create_issue(ticket_data)
            except (KeyError, AttributeError):
                pass  # May fail on verify-after-create; we only care about the first call

        assert len(captured_cmds) >= 1
        create_cmd = captured_cmds[0]
        assert "--type" in create_cmd, (
            f"ACLI create command should include --type. Got: {create_cmd}"
        )
        type_idx = create_cmd.index("--type")
        assert create_cmd[type_idx + 1] == "Bug"  # capitalized

    @pytest.mark.xfail(
        reason="AcliClient.create_issue() only extracts ticket_type and title; "
        "description is silently dropped (acli-integration.py:290-299)",
        strict=True,
    )
    def test_acli_create_sends_description(
        self, acli_mod: Any, acli_capture: Any
    ) -> None:
        """AcliClient.create_issue() should send the description to ACLI."""
        client, captured_cmds, fake_run_acli = acli_capture

        ticket_data = {
            "ticket_type": "bug",
            "title": "Test",
            "description": "Important bug description",
        }

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            try:
                client.create_issue(ticket_data)
            except TypeError:
                pytest.fail(
                    "create_issue() raised TypeError — patch may not be intercepting correctly"
                )

        assert len(captured_cmds) >= 1, "At least one ACLI command should be issued"
        create_cmd = captured_cmds[0]
        assert "--description" in create_cmd, (
            f"ACLI create command should include --description flag. Got: {create_cmd}"
        )

    @pytest.mark.xfail(
        reason="AcliClient.create_issue() only extracts ticket_type and title; "
        "priority is silently dropped (acli-integration.py:290-299)",
        strict=True,
    )
    def test_acli_create_sends_priority(self, acli_mod: Any, acli_capture: Any) -> None:
        """AcliClient.create_issue() should send the priority to ACLI."""
        client, captured_cmds, fake_run_acli = acli_capture

        ticket_data = {
            "ticket_type": "bug",
            "title": "Test",
            "priority": 1,
        }

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            try:
                client.create_issue(ticket_data)
            except TypeError:
                pytest.fail(
                    "create_issue() raised TypeError — patch may not be intercepting correctly"
                )

        assert len(captured_cmds) >= 1, "At least one ACLI command should be issued"
        create_cmd = captured_cmds[0]
        assert "--priority" in create_cmd, (
            f"ACLI create command should include --priority flag. Got: {create_cmd}"
        )

    @pytest.mark.xfail(
        reason="AcliClient.create_issue() only extracts ticket_type and title; "
        "assignee is silently dropped (acli-integration.py:290-299)",
        strict=True,
    )
    def test_acli_create_sends_assignee(self, acli_mod: Any, acli_capture: Any) -> None:
        """AcliClient.create_issue() should send the assignee to ACLI."""
        client, captured_cmds, fake_run_acli = acli_capture

        ticket_data = {
            "ticket_type": "bug",
            "title": "Test",
            "assignee": "alice",
        }

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            try:
                client.create_issue(ticket_data)
            except TypeError:
                pytest.fail(
                    "create_issue() raised TypeError — patch may not be intercepting correctly"
                )

        assert len(captured_cmds) >= 1, "At least one ACLI command should be issued"
        create_cmd = captured_cmds[0]
        assert "--assignee" in create_cmd, (
            f"ACLI create command should include --assignee flag. Got: {create_cmd}"
        )


class TestAcliClientUpdateFieldExtraction:
    """Test which fields AcliClient.update_issue() sends for non-status field updates."""

    def test_acli_update_sends_priority(self, acli_mod: Any, acli_capture: Any) -> None:
        """AcliClient.update_issue() should support sending priority updates."""
        client, captured_cmds, fake_run_acli = acli_capture

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            client.update_issue("TEST-1", priority="High")

        assert len(captured_cmds) >= 1
        edit_cmd = captured_cmds[0]
        assert "--priority" in edit_cmd, (
            f"ACLI edit command should include --priority. Got: {edit_cmd}"
        )

    def test_acli_update_sends_description(
        self, acli_mod: Any, acli_capture: Any
    ) -> None:
        """AcliClient.update_issue() should support sending description updates."""
        client, captured_cmds, fake_run_acli = acli_capture

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            client.update_issue("TEST-1", description="Updated desc")

        assert len(captured_cmds) >= 1
        edit_cmd = captured_cmds[0]
        assert "--description" in edit_cmd, (
            f"ACLI edit command should include --description. Got: {edit_cmd}"
        )

    def test_acli_update_sends_assignee(self, acli_mod: Any, acli_capture: Any) -> None:
        """AcliClient.update_issue() should support sending assignee updates."""
        client, captured_cmds, fake_run_acli = acli_capture

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            client.update_issue("TEST-1", assignee="bob")

        assert len(captured_cmds) >= 1
        edit_cmd = captured_cmds[0]
        assert "--assignee" in edit_cmd, (
            f"ACLI edit command should include --assignee. Got: {edit_cmd}"
        )

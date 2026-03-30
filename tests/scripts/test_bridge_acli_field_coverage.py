"""ACLI client field-extraction tests for the Jira bridge.

Verifies which fields AcliClient.create_issue() and AcliClient.update_issue()
actually send to the ACLI subprocess. The bridge passes the full data dict,
but AcliClient may only extract a subset of those fields for the ACLI command.

Test: python3 -m pytest tests/scripts/test_bridge_acli_field_coverage.py -v
"""

from __future__ import annotations

import json
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
        """AcliClient.create_issue() should send the title/summary to ACLI.

        When priority is present, create uses --from-json (so --summary is in
        the JSON payload, not the CLI args). When priority is absent, --summary
        appears as a CLI flag.
        """
        client, captured_cmds, fake_run_acli = acli_capture

        # Without priority: --summary appears as CLI flag
        ticket_data_no_pri = {
            "ticket_type": "bug",
            "title": "Test Summary",
            "assignee": "alice",
            "description": "Test description",
        }

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            try:
                client.create_issue(ticket_data_no_pri)
            except (KeyError, AttributeError):
                pass

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

    def test_acli_create_sends_priority_via_from_json(
        self, acli_mod: Any, acli_capture: Any
    ) -> None:
        """AcliClient.create_issue() should send priority via --from-json.

        ACLI does not support --priority on create. Priority is set via
        --from-json with additionalAttributes.priority.name in the JSON payload.
        """
        client, captured_cmds, fake_run_acli = acli_capture

        ticket_data = {
            "ticket_type": "bug",
            "title": "Test",
            "priority": 1,
        }

        dumped_payloads: list[Any] = []

        original_dump = json.dump

        def capturing_dump(obj: Any, fp: Any, **kw: Any) -> None:
            dumped_payloads.append(obj)
            original_dump(obj, fp, **kw)

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            with patch.object(acli_mod.json, "dump", side_effect=capturing_dump):
                try:
                    client.create_issue(ticket_data)
                except TypeError:
                    pytest.fail(
                        "create_issue() raised TypeError — patch may not be intercepting correctly"
                    )

        assert len(captured_cmds) >= 1, "At least one ACLI command should be issued"
        create_cmd = captured_cmds[0]
        assert "--from-json" in create_cmd, (
            f"When priority is set, ACLI create should use --from-json. Got: {create_cmd}"
        )

        assert dumped_payloads, "json.dump should have been called to write the payload"
        payload = dumped_payloads[0]
        assert "additionalAttributes" in payload, (
            f"Payload should contain 'additionalAttributes'. Got keys: {list(payload.keys())}"
        )
        priority_field = payload["additionalAttributes"].get("priority", {})
        assert "name" in priority_field, (
            f"additionalAttributes.priority should have a 'name' key. Got: {priority_field}"
        )
        assert priority_field["name"] == "High", (
            f"additionalAttributes.priority.name should be 'High' (mapped from int 1). "
            f"Got: {priority_field['name']!r}"
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

    def test_acli_update_skips_priority_with_warning(
        self, acli_mod: Any, acli_capture: Any, caplog: Any
    ) -> None:
        """AcliClient.update_issue() should skip priority (ACLI doesn't support it).

        ACLI workitem edit does not support --priority or additionalAttributes.
        Priority in kwargs is logged as a warning and skipped.
        See bug 4232-ffd0 / epic 392d-8080.
        """
        import logging

        client, captured_cmds, fake_run_acli = acli_capture

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            with caplog.at_level(logging.WARNING, logger="acli_integration"):
                result = client.update_issue("TEST-1", priority="High")

        # No ACLI edit command should be issued for priority-only updates
        # (the function returns early after popping status and priority)
        assert len(captured_cmds) == 0, (
            f"No ACLI command should be issued for priority-only update. Got: {captured_cmds}"
        )
        assert result == {"key": "TEST-1"}

        # The warning must be emitted with the jira key and priority value
        warning_messages = [
            r.message for r in caplog.records if r.levelno == logging.WARNING
        ]
        assert any("TEST-1" in str(m) for m in warning_messages), (
            f"Expected warning mentioning 'TEST-1' but got: {warning_messages}"
        )
        assert any("High" in str(m) for m in warning_messages), (
            f"Expected warning mentioning 'High' but got: {warning_messages}"
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

    def test_acli_update_description_uses_adf_format(
        self, acli_mod: Any, acli_capture: Any
    ) -> None:
        """AcliClient.update_issue() description must be sent as ADF JSON, not plain text."""
        import json

        client, captured_cmds, fake_run_acli = acli_capture

        with patch.object(acli_mod, "_run_acli", side_effect=fake_run_acli):
            client.update_issue("TEST-1", description="Test ADF conversion")

        assert len(captured_cmds) >= 1
        edit_cmd = captured_cmds[0]
        desc_idx = edit_cmd.index("--description")
        desc_value = edit_cmd[desc_idx + 1]
        parsed = json.loads(desc_value)
        assert parsed.get("type") == "doc", (
            f"Description should be ADF format with type='doc'. Got: {desc_value[:100]}"
        )
        assert parsed.get("version") == 1, "ADF version should be 1"
        assert "content" in parsed, "ADF should have content field"

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

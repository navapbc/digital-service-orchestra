"""Behavioral tests for figma-resync.py — RED phase.

Tests cover all done definitions for story 5250-e85b:
- Tag precondition check (design:awaiting_review required)
- File lock (TTL 30 min, stale-lock cleanup)
- --non-interactive flag auto-confirms
- Tag swap (design:awaiting_review → design:approved)
- Metadata comment format

Tests import figma_resync module from the scripts directory. All external
subprocess calls (ticket CLI, figma-merge.py) are mocked.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Add scripts dir to path so figma_resync can be imported
_SCRIPTS_DIR = (
    Path(__file__).resolve().parent.parent.parent / "plugins" / "dso" / "scripts"
)
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))


def _make_ticket_json(tags: list[str], figma_file_key: str = "abc123") -> str:
    """Build a minimal ticket JSON response."""
    return json.dumps(
        {
            "id": "test-1234",
            "title": "Test story",
            "status": "in_progress",
            "tags": tags,
            "comments": [
                {
                    "body": f"figma_file_key: {figma_file_key}",
                    "created_at": "2026-04-09T12:00:00Z",
                }
            ],
        }
    )


def _make_merge_output(
    status: str = "success",
    components_added: int = 1,
    components_modified: int = 2,
    components_removed: int = 0,
    behavioral_specs_preserved: int = 5,
    warnings: list[str] | None = None,
) -> str:
    payload: dict = {
        "status": status,
        "components_added": components_added,
        "components_modified": components_modified,
        "components_removed": components_removed,
        "behavioral_specs_preserved": behavioral_specs_preserved,
        "warnings": warnings or [],
    }
    return json.dumps(payload)


class TestTagPrecondition(unittest.TestCase):
    """RS-1, RS-2: Tag precondition — design:awaiting_review required."""

    def test_RS1_exits_1_when_tag_absent(self):
        """RS-1: Missing design:awaiting_review → exit 1 with descriptive error."""
        import figma_resync  # noqa: PLC0415

        ticket_json = _make_ticket_json(tags=["some-other-tag"])

        with patch("figma_resync.subprocess") as mock_sub:
            mock_sub.run.return_value = MagicMock(
                returncode=0, stdout=ticket_json, stderr=""
            )
            result = figma_resync.run(
                ticket_id="test-1234",
                non_interactive=True,
                _ticket_show_fn=lambda tid: json.loads(ticket_json),
            )

        self.assertEqual(result, 1)

    def test_RS2_proceeds_when_tag_present(self):
        """RS-2: design:awaiting_review tag present → workflow proceeds."""
        import figma_resync  # noqa: PLC0415

        ticket_data = json.loads(_make_ticket_json(tags=["design:awaiting_review"]))
        merge_out = _make_merge_output()

        with (
            patch("figma_resync.subprocess"),
            patch("figma_resync._run_pull", return_value=(0, "/tmp/fake-spatial.json")),
            patch("figma_resync._run_merge", return_value=(0, json.loads(merge_out))),
            patch("figma_resync._do_tag_swap"),
            patch("figma_resync._record_metadata"),
        ):
            result = figma_resync.run(
                ticket_id="test-1234",
                non_interactive=True,
                _ticket_show_fn=lambda tid: ticket_data,
            )

        self.assertEqual(result, 0)


class TestMissingFigmaFileKey(unittest.TestCase):
    """RS-1b: Missing figma_file_key in comments → exit 1 with descriptive error."""

    def test_RS1b_exits_1_when_no_figma_file_key_in_comments(self):
        """RS-1b: Ticket has awaiting_review tag but no figma_file_key comment → exit 1."""
        import figma_resync  # noqa: PLC0415

        ticket_data = {
            "id": "test-1234",
            "title": "Test story",
            "status": "in_progress",
            "tags": ["design:awaiting_review"],
            "comments": [],  # No figma_file_key comment
        }

        result = figma_resync.run(
            ticket_id="test-1234",
            non_interactive=True,
            _ticket_show_fn=lambda tid: ticket_data,
        )

        self.assertEqual(result, 1)

    def test_RS1c_exits_1_when_comments_have_no_figma_file_key_line(self):
        """RS-1c: Comments exist but none contain figma_file_key: prefix → exit 1."""
        import figma_resync  # noqa: PLC0415

        ticket_data = {
            "id": "test-1234",
            "title": "Test story",
            "status": "in_progress",
            "tags": ["design:awaiting_review"],
            "comments": [
                {
                    "body": "Some note without the figma_file_key line",
                    "created_at": "2026-04-10",
                },
                {
                    "body": "Another comment with no key either",
                    "created_at": "2026-04-10",
                },
            ],
        }

        result = figma_resync.run(
            ticket_id="test-1234",
            non_interactive=True,
            _ticket_show_fn=lambda tid: ticket_data,
        )

        self.assertEqual(result, 1)


class TestFileLock(unittest.TestCase):
    """RS-3, RS-4: File lock TTL and stale-lock cleanup."""

    def test_RS3_exits_1_when_fresh_lock_exists(self):
        """RS-3: Fresh lockfile (within TTL) → exit 1 with 're-sync already in progress'."""
        import figma_resync  # noqa: PLC0415

        ticket_data = json.loads(_make_ticket_json(tags=["design:awaiting_review"]))

        # Use a unique temp path to avoid parallel test interference
        with tempfile.NamedTemporaryFile(
            prefix="dso-figma-resync-test-", suffix=".lock", delete=False
        ) as tf:
            lock_path = Path(tf.name)

        try:
            # Write a fresh lock
            lock_path.write_text(
                json.dumps(
                    {"pid": 99999, "created_at": "now", "ticket_id": "test-1234"}
                )
            )
            # Set mtime to 5 minutes ago (within TTL)
            fresh_mtime = time.time() - 300
            os.utime(lock_path, (fresh_mtime, fresh_mtime))

            with patch("figma_resync._lock_path", return_value=lock_path):
                result = figma_resync.run(
                    ticket_id="test-1234",
                    non_interactive=True,
                    _ticket_show_fn=lambda tid: ticket_data,
                )
        finally:
            lock_path.unlink(missing_ok=True)

        self.assertEqual(result, 1)

    def test_RS4_stale_lock_cleaned_up_and_proceeds(self):
        """RS-4: Stale lock (>30 min) is removed; workflow proceeds normally."""
        import figma_resync  # noqa: PLC0415

        ticket_data = json.loads(_make_ticket_json(tags=["design:awaiting_review"]))
        merge_out = _make_merge_output()

        # Use a unique temp file path (deleted so _acquire_lock can create it atomically)
        with tempfile.NamedTemporaryFile(
            prefix="dso-figma-resync-test-", suffix=".lock", delete=False
        ) as tf:
            lock_path = Path(tf.name)

        try:
            # Write a stale lock (>30 min ago)
            lock_path.write_text(
                json.dumps(
                    {"pid": 99999, "created_at": "old", "ticket_id": "test-1234"}
                )
            )
            stale_mtime = time.time() - (31 * 60)
            os.utime(lock_path, (stale_mtime, stale_mtime))

            with (
                patch("figma_resync._lock_path", return_value=lock_path),
                patch(
                    "figma_resync._run_pull", return_value=(0, "/tmp/fake-spatial.json")
                ),
                patch(
                    "figma_resync._run_merge", return_value=(0, json.loads(merge_out))
                ),
                patch("figma_resync._do_tag_swap"),
                patch("figma_resync._record_metadata"),
            ):
                result = figma_resync.run(
                    ticket_id="test-1234",
                    non_interactive=True,
                    _ticket_show_fn=lambda tid: ticket_data,
                )
        finally:
            lock_path.unlink(missing_ok=True)

        self.assertEqual(result, 0)
        # Stale lock should have been removed and replaced; check it no longer points to old pid
        # (The finally block removes it, so just verify run returned 0)


class TestNonInteractiveFlag(unittest.TestCase):
    """RS-5: --non-interactive flag auto-confirms without prompting."""

    def test_RS5_non_interactive_exits_0_without_prompt(self):
        """RS-5: --non-interactive → no confirmation prompt; exits 0."""
        import figma_resync  # noqa: PLC0415

        ticket_data = json.loads(_make_ticket_json(tags=["design:awaiting_review"]))
        merge_out = _make_merge_output(components_added=1, components_removed=1)

        tag_swap_called = []
        metadata_called = []

        def fake_tag_swap(ticket_id, ticket_show_fn):
            tag_swap_called.append(ticket_id)

        def fake_record_metadata(ticket_id, metadata):
            metadata_called.append(ticket_id)

        with (
            patch("figma_resync._run_pull", return_value=(0, "/tmp/fake-spatial.json")),
            patch("figma_resync._run_merge", return_value=(0, json.loads(merge_out))),
            patch("figma_resync._do_tag_swap", side_effect=fake_tag_swap),
            patch("figma_resync._record_metadata", side_effect=fake_record_metadata),
            patch(
                "builtins.input",
                side_effect=AssertionError("input() called in non-interactive mode"),
            ),
        ):
            result = figma_resync.run(
                ticket_id="test-1234",
                non_interactive=True,
                _ticket_show_fn=lambda tid: ticket_data,
            )

        self.assertEqual(result, 0)
        self.assertEqual(tag_swap_called, ["test-1234"])
        self.assertEqual(metadata_called, ["test-1234"])


class TestTagSwap(unittest.TestCase):
    """RS-6: Tag swap — design:awaiting_review → design:approved after successful merge."""

    def test_RS6_tag_swap_replaces_awaiting_review_with_approved(self):
        """RS-6: After successful merge, tag swap removes awaiting_review, adds approved."""
        import figma_resync  # noqa: PLC0415

        recorded_calls = []

        def fake_ticket_cmd(*args, **kwargs):
            recorded_calls.append(args)
            return MagicMock(returncode=0, stdout="", stderr="")

        ticket_data = json.loads(
            _make_ticket_json(tags=["design:awaiting_review", "priority:high"])
        )

        with patch("figma_resync.subprocess") as mock_sub:
            mock_sub.run.side_effect = fake_ticket_cmd
            figma_resync._do_tag_swap("test-1234", lambda tid: ticket_data)

        # Should have called ticket edit with --tags argument
        self.assertTrue(recorded_calls, "Expected at least one subprocess.run call")
        # Extract the cmd list from the first call (args[0] of subprocess.run)
        cmd = recorded_calls[0][0]
        # Find the '--tags' argument and get the value immediately after it
        self.assertIn("--tags", cmd, "Expected '--tags' in subprocess command")
        tags_idx = cmd.index("--tags")
        tags_value = cmd[tags_idx + 1]
        # Tags value must be a comma-separated string containing 'design:approved'
        tags_list = tags_value.split(",")
        self.assertIn(
            "design:approved",
            tags_list,
            f"Expected 'design:approved' in tags list, got: {tags_list}",
        )
        # Tags value must NOT contain 'design:awaiting_review'
        self.assertNotIn(
            "design:awaiting_review",
            tags_list,
            f"Expected 'design:awaiting_review' to be removed, got: {tags_list}",
        )


class TestMetadataComment(unittest.TestCase):
    """RS-7: Metadata comment includes all required fields."""

    def test_RS7_metadata_comment_contains_required_fields(self):
        """RS-7: Metadata comment JSON contains figma_file_key, timestamp, counts."""
        import figma_resync  # noqa: PLC0415

        captured_cmds = []

        def fake_comment_cmd(*args, **kwargs):
            cmd = args[0] if args else []
            captured_cmds.append(list(cmd))
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch("figma_resync.subprocess") as mock_sub:
            mock_sub.run.side_effect = fake_comment_cmd
            figma_resync._record_metadata(
                "test-1234",
                {
                    "figma_file_key": "abc123",
                    "timestamp": "2026-04-10T12:00:00Z",
                    "components_added": 1,
                    "components_modified": 2,
                    "components_removed": 0,
                    "behavioral_specs_preserved": 5,
                },
            )

        self.assertTrue(captured_cmds, "Expected at least one subprocess.run call")
        # The comment body is the last element in the cmd list
        comment_body = captured_cmds[0][-1]
        # Parse as JSON to inspect the exact fields
        try:
            comment_data = json.loads(comment_body)
        except json.JSONDecodeError:
            self.fail(f"Comment body is not valid JSON: {comment_body!r}")

        required_fields = [
            "figma_file_key",
            "timestamp",
            "components_added",
            "components_modified",
            "components_removed",
            "behavioral_specs_preserved",
        ]
        for field in required_fields:
            self.assertIn(
                field,
                comment_data,
                f"Required field '{field}' missing from metadata comment body",
            )


if __name__ == "__main__":
    unittest.main()

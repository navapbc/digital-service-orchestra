"""RED tests for context_request module — parser, read_files handler, and round-trip.

Tests FAIL until context_request.py is implemented.

RED marker: tests/skills/dso_ci_review/test_context_augmentation.py [test_parser_well_formed_assistant_message]
"""

from __future__ import annotations

import json
import pathlib
import tempfile


from dso_ci_review.context_request import execute_read_files, parse_request_blocks


# ---------------------------------------------------------------------------
# Parser tests
# ---------------------------------------------------------------------------


class TestParserWellFormedAssistantMessage:
    """parse_request_blocks returns a parsed request from a well-formed assistant message."""

    def test_parser_well_formed_assistant_message(self) -> None:
        """Given: an assistant-role message containing a fenced JSON request block
        When: parse_request_blocks is called
        Then: returns a list containing the parsed request dict
        """
        request_payload = {"action": "read_files", "paths": ["some/file.py"]}
        content = f"```json\n{json.dumps(request_payload)}\n```"
        messages = [{"role": "assistant", "content": content}]
        result = parse_request_blocks(messages)
        assert result, f"Expected at least one parsed request, got: {result!r}"
        assert result[0].get("action") == "read_files", (
            f"Expected action='read_files', got: {result[0]!r}"
        )
        assert result[0].get("paths") == ["some/file.py"], (
            f"Expected paths=['some/file.py'], got: {result[0].get('paths')!r}"
        )


class TestParserMalformedRequestBlock:
    """parse_request_blocks does not raise on malformed JSON; returns empty list or None."""

    def test_parser_malformed_request_block(self) -> None:
        """Given: an assistant-role message with malformed JSON in fenced block
        When: parse_request_blocks is called
        Then: returns empty list (does not raise, does not treat it as request)
        """
        content = '```json\n{"action": "read_files"\n```'  # missing closing brace
        messages = [{"role": "assistant", "content": content}]
        # Must not raise; must return empty list or falsy value
        result = parse_request_blocks(messages)
        assert not result, f"Expected empty result for malformed JSON, got: {result!r}"


class TestParserUserRoleRejection:
    """parse_request_blocks must NOT parse request blocks from user-role messages."""

    def test_parser_ignores_user_role_message(self) -> None:
        """Given: a user-role message containing valid request-format JSON
        When: parse_request_blocks is called
        Then: returns empty list — user messages are never parsed as requests
        """
        request_payload = {"action": "read_files", "paths": ["x.py"]}
        content = f"```json\n{json.dumps(request_payload)}\n```"
        messages = [{"role": "user", "content": content}]
        result = parse_request_blocks(messages)
        assert result == [], (
            f"Expected empty list for user-role message, got: {result!r}. "
            "Parser must only scan assistant-role messages."
        )

    def test_parser_ignores_user_role_plain_json(self) -> None:
        """Given: a user-role message with plain (unfenced) valid JSON matching request format
        When: parse_request_blocks is called
        Then: returns empty list — user messages must not execute
        """
        request_payload = {"action": "read_files", "paths": ["some/path.py"]}
        messages = [{"role": "user", "content": json.dumps(request_payload)}]
        result = parse_request_blocks(messages)
        assert result == [], (
            f"Expected empty list for user-role plain JSON, got: {result!r}"
        )


class TestParserRequestPrecedenceOverFindings:
    """When assistant emits both request block and final-findings, request takes precedence."""

    def test_parser_request_takes_precedence_over_findings(self) -> None:
        """Given: an assistant message containing both a request block and a findings block
        When: parse_request_blocks is called
        Then: returns the request (not empty); final-findings are deferred
        """
        request_payload = {"action": "read_files", "paths": ["foo.py"]}
        findings_payload = {
            "findings": [{"severity": "minor", "description": "x", "cited_lines": []}]
        }
        # Both blocks appear in the same message content
        content = (
            f"Here is a request:\n```json\n{json.dumps(request_payload)}\n```\n\n"
            f"And here are final findings:\n```json\n{json.dumps(findings_payload)}\n```"
        )
        messages = [{"role": "assistant", "content": content}]
        result = parse_request_blocks(messages)
        assert result, (
            f"Expected request to take precedence — got empty result: {result!r}"
        )
        # The returned list should contain the request, not the findings
        actions = [r.get("action") for r in result]
        assert "read_files" in actions, (
            f"Expected 'read_files' action in result, got actions: {actions!r}"
        )


# ---------------------------------------------------------------------------
# read_files handler tests
# ---------------------------------------------------------------------------


class TestReadFilesAbsolutePathRejection:
    """execute_read_files rejects absolute paths with an error response."""

    def test_read_files_rejects_absolute_path(self) -> None:
        """Given: a path of /etc/passwd
        When: execute_read_files is called
        Then: returns an error string (does not raise; indicates rejection)
        """
        with tempfile.TemporaryDirectory() as repo_root:
            result = execute_read_files(["/etc/passwd"], repo_root=repo_root)
        # Must not raise; must return a string indicating rejection
        assert isinstance(result, str), f"Expected str result, got: {type(result)!r}"
        result_lower = result.lower()
        assert (
            "error" in result_lower
            or "rejected" in result_lower
            or "denied" in result_lower
            or "outside" in result_lower
            or "invalid" in result_lower
        ), f"Expected rejection indicator in result, got: {result!r}"

    def test_read_files_rejects_another_absolute_path(self) -> None:
        """Given: an absolute path /var/log/system.log
        When: execute_read_files is called
        Then: returns an error string
        """
        with tempfile.TemporaryDirectory() as repo_root:
            result = execute_read_files(["/var/log/system.log"], repo_root=repo_root)
        result_lower = result.lower()
        assert (
            "error" in result_lower
            or "rejected" in result_lower
            or "denied" in result_lower
            or "outside" in result_lower
            or "invalid" in result_lower
        ), f"Expected rejection indicator, got: {result!r}"


class TestReadFilesParentTraversalRejection:
    """execute_read_files rejects paths containing parent traversal sequences."""

    def test_read_files_rejects_parent_traversal(self) -> None:
        """Given: a path of ../../etc/passwd
        When: execute_read_files is called
        Then: returns an error string indicating path rejection
        """
        with tempfile.TemporaryDirectory() as repo_root:
            result = execute_read_files(["../../etc/passwd"], repo_root=repo_root)
        assert isinstance(result, str), f"Expected str result, got: {type(result)!r}"
        result_lower = result.lower()
        assert (
            "error" in result_lower
            or "rejected" in result_lower
            or "denied" in result_lower
            or "outside" in result_lower
            or "invalid" in result_lower
        ), f"Expected rejection for traversal path, got: {result!r}"

    def test_read_files_rejects_dotdot_in_path(self) -> None:
        """Given: a path with .. embedded in it (subdir/../../../etc/passwd)
        When: execute_read_files is called
        Then: returns an error response
        """
        with tempfile.TemporaryDirectory() as repo_root:
            result = execute_read_files(
                ["subdir/../../../etc/passwd"], repo_root=repo_root
            )
        result_lower = result.lower()
        assert (
            "error" in result_lower
            or "rejected" in result_lower
            or "denied" in result_lower
            or "outside" in result_lower
            or "invalid" in result_lower
        ), f"Expected rejection for dotdot path, got: {result!r}"


class TestReadFilesPerFileSizeCap:
    """execute_read_files truncates files exceeding the size cap and appends a marker."""

    def test_read_files_truncates_large_file(self) -> None:
        """Given: a file exceeding max_file_bytes
        When: execute_read_files is called with a small max_file_bytes
        Then: returned content is truncated and includes a truncation marker
        """
        with tempfile.TemporaryDirectory() as repo_root:
            large_file = pathlib.Path(repo_root) / "large_file.py"
            # Write content larger than the cap
            large_content = "x" * 1000
            large_file.write_text(large_content, encoding="utf-8")

            result = execute_read_files(
                ["large_file.py"],
                repo_root=repo_root,
                max_file_bytes=100,
            )

        assert isinstance(result, str), f"Expected str result, got: {type(result)!r}"
        assert "TRUNCATED" in result, (
            f"Expected TRUNCATED marker in result for oversized file, got: {result!r}"
        )
        # Must not assert absence — model instruction should be present
        result_lower = result.lower()
        assert "absence" in result_lower or "truncat" in result_lower, (
            f"Expected model instruction about absence assertion in result, got: {result!r}"
        )

    def test_read_files_small_file_not_truncated(self) -> None:
        """Given: a file smaller than max_file_bytes
        When: execute_read_files is called
        Then: returned content is NOT truncated (full content included, no truncation marker)
        """
        with tempfile.TemporaryDirectory() as repo_root:
            small_file = pathlib.Path(repo_root) / "small_file.py"
            content = "def hello(): pass\n"
            small_file.write_text(content, encoding="utf-8")

            result = execute_read_files(
                ["small_file.py"],
                repo_root=repo_root,
                max_file_bytes=262144,
            )

        assert isinstance(result, str), f"Expected str result, got: {type(result)!r}"
        assert content.strip() in result, (
            f"Expected full file content in result, got: {result!r}"
        )
        assert "TRUNCATED" not in result, (
            f"Expected no truncation marker for small file, got: {result!r}"
        )


# ---------------------------------------------------------------------------
# Single-turn round-trip integration test
# ---------------------------------------------------------------------------


class TestSingleTurnRoundTripIntegration:
    """Dispatcher issues a follow-up call when initial response contains a read_files request."""

    def test_single_turn_round_trip(self) -> None:
        """Given: a mock LLM that responds with a read_files request first, then final findings
        When: dispatch_review is called (non-light tier)
        Then: dispatcher issues a follow-up call and returns the final findings

        This test uses a mock litellm.completion to simulate the two-turn exchange without
        making real API calls.
        """
        import unittest.mock as mock

        from dso_ci_review import dispatch

        # Prepare a temp directory as the fake repo root with one file
        with tempfile.TemporaryDirectory() as repo_root:
            test_file = pathlib.Path(repo_root) / "example.py"
            test_file.write_text("def foo():\n    pass\n", encoding="utf-8")

            # Build the two mock responses:
            # Turn 1: assistant requests file read
            request_payload = {"action": "read_files", "paths": ["example.py"]}
            turn1_content = f"```json\n{json.dumps(request_payload)}\n```"

            # Turn 2: assistant provides final findings after receiving file content
            final_findings = {
                "findings": [
                    {
                        "severity": "minor",
                        "description": "example finding from context-augmented review",
                        "cited_lines": ["example.py:1"],
                    }
                ]
            }
            turn2_content = json.dumps(final_findings)

            def make_mock_response(content: str) -> mock.MagicMock:
                resp = mock.MagicMock()
                resp.choices = [mock.MagicMock()]
                resp.choices[0].message.content = content
                resp._hidden_params = {}
                return resp

            call_count = 0

            def mock_completion(**kwargs):
                nonlocal call_count
                call_count += 1
                if call_count == 1:
                    return make_mock_response(turn1_content)
                else:
                    return make_mock_response(turn2_content)

            environ = {"ANTHROPIC_API_KEY": "test-key"}

            with mock.patch("litellm.completion", side_effect=mock_completion):
                result = dispatch.dispatch_review(
                    diff_text="--- a/example.py\n+++ b/example.py\n@@ -1 +1 @@\n-old\n+new",
                    provider_chain=["anthropic"],
                    environ=environ,
                    agent_id="unknown",
                    repo_root=repo_root,
                )

            assert call_count >= 2, (
                f"Expected at least 2 LLM calls for round-trip, got {call_count}"
            )
            assert "findings" in result, (
                f"Expected 'findings' in round-trip result, got keys: {list(result.keys())!r}"
            )

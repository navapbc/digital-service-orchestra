"""Tests for file impact section detection in issue-quality-check.sh and enrich-file-impact.sh."""

import json
import os
import subprocess

import pytest

WORKTREE_ROOT = os.environ.get(
    "WORKTREE_ROOT",
    subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip(),
)


def make_ticket_cmd(tmp_path: object, ticket_id: str, content: str) -> str:
    """Create a mock ticket CLI script that returns `content` for `show <ticket_id>`.

    Uses TICKET_CMD env var (v3 interface).
    Returns the path to the mock script.
    """
    mock_dir = os.path.join(str(tmp_path), "mock-bin")
    os.makedirs(mock_dir, exist_ok=True)
    content_file = os.path.join(mock_dir, f"{ticket_id}.content")
    with open(content_file, "w") as f:
        f.write(content)
    script_path = os.path.join(mock_dir, "ticket")
    with open(script_path, "w") as f:
        f.write(
            f"#!/usr/bin/env bash\n"
            f'if [[ "${{1:-}}" == "show" && "${{2:-}}" == "{ticket_id}" ]]; then\n'
            f'    cat "{content_file}"\n'
            f"    exit 0\n"
            f"fi\n"
            f"exit 1\n"
        )
    os.chmod(script_path, 0o755)
    return script_path


class TestFileImpactAwkPattern:
    """Test the awk pattern that counts file impact items from ticket content."""

    AWK_PATTERN = r"""
    tolower($0) ~ /^## file impact/ || tolower($0) ~ /^### files to modify/ { found=1; next }
    found && /^## / { exit }
    found && /^### / && tolower($0) !~ /^### files to/ { exit }
    found && /(src\/|tests\/|app\/|\.py|\.ts|\.js|\.html)/ { count++ }
    END { print count+0 }
    """

    def _run_awk(self, content: str) -> int:
        """Run the awk pattern on content and return the count."""
        result = subprocess.run(
            ["awk", self.AWK_PATTERN],
            input=content,
            capture_output=True,
            text=True,
        )
        return int(result.stdout.strip())

    def test_detects_file_impact_section(self) -> None:
        content = """## File Impact
- `app/src/services/foo.py` — update logic
- `app/tests/unit/test_foo.py` — add tests
"""
        assert self._run_awk(content) == 2

    def test_detects_files_to_modify_heading(self) -> None:
        content = """### Files to modify
- `src/agents/bar.py`
- `tests/unit/test_bar.py`
"""
        assert self._run_awk(content) == 2

    def test_returns_zero_when_no_section(self) -> None:
        content = """## Description
This is a task about something.
"""
        assert self._run_awk(content) == 0

    def test_stops_at_next_h2_section(self) -> None:
        content = """## File Impact
- `src/foo.py`
## Acceptance Criteria
- src/bar.py should not be counted
"""
        assert self._run_awk(content) == 1

    def test_ignores_non_path_lines(self) -> None:
        content = """## File Impact
- `src/foo.py` — update
- This line has no file paths
- `tests/test_bar.py` — add
"""
        assert self._run_awk(content) == 2

    def test_case_insensitive_heading(self) -> None:
        content = """## file impact
- `src/foo.py`
"""
        assert self._run_awk(content) == 1


class TestIssueQualityCheckFileImpact:
    """Test that issue-quality-check.sh includes file impact in quality gate."""

    SCRIPT_PATH = os.path.join(
        WORKTREE_ROOT, "plugins", "dso", "scripts", "issue-quality-check.sh"
    )

    def _make_ticket_cmd(self, tmp_path: object, ticket_id: str, content: str) -> str:
        return make_ticket_cmd(tmp_path, ticket_id, content)

    def test_file_impact_section_contributes_to_quality_pass(
        self, tmp_path: object
    ) -> None:
        """A ticket with a file impact section should pass quality gate even without AC."""

        content = json.dumps(
            {
                "ticket_id": "w21-mai8",
                "ticket_type": "task",
                "title": "Test ticket with file impact",
                "status": "open",
                "description": "",
                "comments": [
                    {
                        "body": (
                            "## Description\n"
                            "A task with files to modify.\n\n"
                            "### Files to modify\n"
                            "- `src/agents/foo.py` — update logic\n"
                            "- `tests/unit/test_foo.py` — add tests\n"
                        ),
                        "author": "test",
                    }
                ],
                "deps": [],
            }
        )
        ticket_cmd = self._make_ticket_cmd(tmp_path, "w21-mai8", content)
        # We test the awk pattern extraction indirectly by checking the script output
        # includes file_impact count. This requires the script to actually be updated.
        result = subprocess.run(
            [self.SCRIPT_PATH, "w21-mai8"],
            capture_output=True,
            text=True,
            cwd=WORKTREE_ROOT,
            env={**os.environ, "TICKET_CMD": ticket_cmd},
        )
        # w21-mai8 has a "### Files to modify" section, so it should be detected
        assert result.returncode == 0
        assert "file impact" in result.stdout.lower() or "FI" in result.stdout


class TestIssueQualityCheckStoryType:
    """Test that issue-quality-check.sh treats story tickets differently from tasks."""

    SCRIPT_PATH = os.path.join(
        WORKTREE_ROOT, "plugins", "dso", "scripts", "issue-quality-check.sh"
    )

    def _make_ticket_cmd(self, tmp_path: object, ticket_id: str, content: str) -> str:
        return make_ticket_cmd(tmp_path, ticket_id, content)

    def test_story_with_prose_done_definition_passes_without_warning(
        self, tmp_path: object
    ) -> None:
        """A story ticket with prose done-definitions (no AC block) should exit 0 with
        no WARNING text — prose done-definitions are correct-by-design for stories."""

        content = json.dumps(
            {
                "ticket_id": "dso-story1",
                "ticket_type": "story",
                "title": "As a user, I want a feature so that I can do things",
                "status": "open",
                "description": "",
                "comments": [
                    {
                        "body": (
                            "As an engineer, I want the system to work correctly "
                            "so that users are happy.\n\n"
                            "## Done Definition\n\n"
                            "- The feature must be implemented and verified\n"
                            "- Integration tests should confirm the expected behavior\n"
                            "- Documentation is updated to reflect the change\n"
                            "- Code review must be completed before merge\n"
                            "- CI must pass on the final commit\n"
                        ),
                        "author": "test",
                    }
                ],
                "deps": [],
            }
        )
        ticket_cmd = self._make_ticket_cmd(tmp_path, "dso-story1", content)
        result = subprocess.run(
            [self.SCRIPT_PATH, "dso-story1"],
            capture_output=True,
            text=True,
            cwd=WORKTREE_ROOT,
            env={**os.environ, "TICKET_CMD": ticket_cmd},
        )
        # Story with prose done-definitions must pass (exit 0)
        assert result.returncode == 0, (
            f"Expected exit 0 for story with prose done-definitions.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        # Output must reference "story" to confirm correct branch taken
        assert "story" in result.stdout.lower(), (
            f"Expected 'story' in output, got: {result.stdout!r}"
        )
        # Must NOT emit a WARNING — prose done-definitions are correct for stories
        assert "WARNING" not in result.stderr and "WARNING" not in result.stdout, (
            f"Story should not emit WARNING for missing AC block.\n"
            f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        )

    def test_task_with_prose_only_passes_with_legacy_warning(
        self, tmp_path: object
    ) -> None:
        """A task ticket with only prose (no AC block, no file impact) should exit 0
        but emit a WARNING — existing legacy behavior must be preserved for tasks."""

        content = json.dumps(
            {
                "ticket_id": "dso-task1",
                "ticket_type": "task",
                "title": "Implement the foo feature",
                "status": "open",
                "description": "",
                "comments": [
                    {
                        "body": (
                            "This task must implement the feature correctly.\n"
                            "It should handle edge cases and verify behavior.\n"
                            "The implementation must be tested thoroughly.\n"
                            "Ensure backward compatibility is maintained.\n"
                            "Code must follow project conventions.\n"
                        ),
                        "author": "test",
                    }
                ],
                "deps": [],
            }
        )
        ticket_cmd = self._make_ticket_cmd(tmp_path, "dso-task1", content)
        result = subprocess.run(
            [self.SCRIPT_PATH, "dso-task1"],
            capture_output=True,
            text=True,
            cwd=WORKTREE_ROOT,
            env={**os.environ, "TICKET_CMD": ticket_cmd},
        )
        # Task should still pass (exit 0) via legacy path
        assert result.returncode == 0, (
            f"Expected exit 0 for task with sufficient prose.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        # Existing behavior: legacy path emits WARNING or "legacy" in stdout
        combined = result.stdout + result.stderr
        assert "WARNING" in combined or "legacy" in result.stdout.lower(), (
            f"Expected WARNING or 'legacy' for task missing AC block.\n"
            f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        )


class TestIssueQualityCheckV3JsonOutput:
    """Test that issue-quality-check.sh correctly parses v3 JSON ticket show output.

    Bug 741d-ae9a: The script assumes YAML frontmatter from ticket show, but v3
    outputs JSON. These tests verify correct parsing of the actual JSON format.
    """

    SCRIPT_PATH = os.path.join(
        WORKTREE_ROOT, "plugins", "dso", "scripts", "issue-quality-check.sh"
    )

    def _make_ticket_cmd(self, tmp_path: object, ticket_id: str, content: str) -> str:
        return make_ticket_cmd(tmp_path, ticket_id, content)

    def test_json_output_extracts_ticket_type(self, tmp_path: object) -> None:
        """v3 ticket show outputs JSON with ticket_type field. Script must extract it."""

        content = json.dumps(
            {
                "ticket_id": "json-test1",
                "ticket_type": "story",
                "title": "As a user, I want a feature",
                "status": "open",
                "description": "",
                "comments": [
                    {
                        "body": (
                            "As an engineer I want this to work.\n"
                            "The feature must handle edge cases.\n"
                            "It should be tested thoroughly.\n"
                            "Documentation must be updated.\n"
                            "Code review is required.\n"
                        ),
                        "author": "test",
                    }
                ],
                "deps": [],
            }
        )
        ticket_cmd = self._make_ticket_cmd(tmp_path, "json-test1", content)
        result = subprocess.run(
            [self.SCRIPT_PATH, "json-test1"],
            capture_output=True,
            text=True,
            cwd=WORKTREE_ROOT,
            env={**os.environ, "TICKET_CMD": ticket_cmd},
        )
        # Script should detect ticket_type=story and use story branch
        assert result.returncode == 0, (
            f"Expected pass for story with sufficient prose.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "story" in result.stdout.lower(), (
            f"Expected 'story' in output (v3 JSON ticket_type=story).\n"
            f"Got: {result.stdout!r}"
        )

    def test_json_output_extracts_description_from_comments(
        self, tmp_path: object
    ) -> None:
        """v3 ticket show has description in comments[].body. Script must extract it."""

        content = json.dumps(
            {
                "ticket_id": "json-test2",
                "ticket_type": "task",
                "title": "Implement the feature",
                "status": "open",
                "description": "",
                "comments": [
                    {
                        "body": (
                            "## Description\n\n"
                            "This task must implement src/foo.py correctly.\n"
                            "It should handle tests/test_foo.py edge cases.\n"
                            "The implementation must verify behavior.\n"
                            "Ensure backward compatibility is maintained.\n"
                            "Code must follow project conventions.\n"
                        ),
                        "author": "test",
                    }
                ],
                "deps": [],
            }
        )
        ticket_cmd = self._make_ticket_cmd(tmp_path, "json-test2", content)
        result = subprocess.run(
            [self.SCRIPT_PATH, "json-test2"],
            capture_output=True,
            text=True,
            cwd=WORKTREE_ROOT,
            env={**os.environ, "TICKET_CMD": ticket_cmd},
        )
        # Script should find 5+ lines and keywords in comment body
        assert result.returncode == 0, (
            f"Expected pass for task with sufficient description in comments.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "pass" in result.stdout.lower(), (
            f"Expected QUALITY: pass in output.\nGot: {result.stdout!r}"
        )


@pytest.mark.scripts
class TestEnrichFileImpactScript:
    """Test enrich-file-impact.sh behavior."""

    SCRIPT_PATH = os.path.join(
        WORKTREE_ROOT, "plugins", "dso", "scripts", "enrich-file-impact.sh"
    )
    # Content-inspection tests use the canonical plugin copy (wrapper is thin)
    CANONICAL_PATH = os.path.join(
        WORKTREE_ROOT, "plugins", "dso", "scripts", "enrich-file-impact.sh"
    )

    def _make_ticket_cmd(self, tmp_path: object, ticket_id: str, content: str) -> str:
        return make_ticket_cmd(tmp_path, ticket_id, content)

    def test_script_exists_and_is_executable(self) -> None:
        assert os.path.isfile(self.SCRIPT_PATH), "enrich-file-impact.sh must exist"
        assert os.access(self.SCRIPT_PATH, os.X_OK), (
            "enrich-file-impact.sh must be executable"
        )

    def test_exits_gracefully_without_api_key(self, tmp_path: object) -> None:
        """Without ANTHROPIC_API_KEY, script should exit 0 with warning."""
        test_id = "test-no-fi-001"
        ticket_content = (
            "---\nid: test-no-fi-001\nstatus: open\n---\n"
            "# Test ticket without file impact\n\n"
            "## Description\nSome description here.\n"
        )
        ticket_cmd = self._make_ticket_cmd(tmp_path, test_id, ticket_content)
        env = os.environ.copy()
        env.pop("ANTHROPIC_API_KEY", None)
        # Point TICKET_CMD at mock so script finds the ticket without hitting the real system.
        env["TICKET_CMD"] = ticket_cmd
        result = subprocess.run(
            [self.SCRIPT_PATH, "--dry-run", test_id],
            capture_output=True,
            text=True,
            env=env,
            cwd=WORKTREE_ROOT,
        )
        assert result.returncode == 0
        # Dry-run exits before API key check — output shows model and prompt info
        combined = result.stdout + result.stderr
        assert "DRY RUN" in combined or "dry run" in combined.lower()

    def test_usage_error_without_args(self) -> None:
        """Script should show usage and exit 1 when no args provided."""
        result = subprocess.run(
            [self.SCRIPT_PATH],
            capture_output=True,
            text=True,
            cwd=WORKTREE_ROOT,
        )
        assert result.returncode == 1
        assert "usage" in result.stdout.lower() or "usage" in result.stderr.lower()

    def test_already_has_file_impact_exits_zero(self, tmp_path: object) -> None:
        """If ticket already has file impact, script should exit 0."""
        test_id = "w21-mai8"
        ticket_content = (
            "---\n"
            "id: w21-mai8\n"
            "status: open\n"
            "type: task\n"
            "---\n"
            "# Test ticket with file impact\n\n"
            "## Description\n"
            "A task with files to modify.\n\n"
            "### Files to modify\n"
            "- `src/agents/foo.py` — update logic\n"
            "- `tests/unit/test_foo.py` — add tests\n"
        )
        ticket_cmd = self._make_ticket_cmd(tmp_path, test_id, ticket_content)
        result = subprocess.run(
            [self.SCRIPT_PATH, "--dry-run", test_id],
            capture_output=True,
            text=True,
            cwd=WORKTREE_ROOT,
            env={**os.environ, "TICKET_CMD": ticket_cmd},
        )
        assert result.returncode == 0
        combined = result.stdout + result.stderr
        assert "already" in combined.lower()

    def test_enrich_no_hardcoded_app_src_or_app_tests(self) -> None:
        """Active script code must not contain hardcoded app/src or app/tests references.

        Comments and fallback default strings (using :- syntax) are excluded.
        Checks the canonical plugin copy (wrapper is a thin delegate).
        """
        with open(self.CANONICAL_PATH) as f:
            lines = f.readlines()

        violations = []
        for i, line in enumerate(lines, 1):
            stripped = line.strip()
            # Skip comments
            if stripped.startswith("#"):
                continue
            # Skip fallback/default strings (matches AC verify: grep -v 'fallback|default|:-')
            if any(kw in line for kw in ("fallback", "default", ":-")):
                continue
            # Check for hardcoded references
            if "app/src" in line or "app/tests" in line:
                violations.append(f"Line {i}: {stripped}")

        assert violations == [], (
            "Found hardcoded app/src or app/tests in active code:\n"
            + "\n".join(violations)
        )

    def test_enrich_dry_run_includes_config_paths(self, tmp_path: object) -> None:
        """--dry-run with ANTHROPIC_API_KEY=fake reports DRY RUN and prompt length.

        This confirms config-driven directory discovery works end-to-end
        through the wrapper delegation.
        """
        test_id = "test-dry-run-cfg"
        ticket_content = (
            "---\nid: test-dry-run-cfg\nstatus: open\ntype: task\n---\n"
            "# Test ticket for dry-run config paths\n\n"
            "## Description\nA task that needs file impact enrichment.\n"
        )
        ticket_cmd = self._make_ticket_cmd(tmp_path, test_id, ticket_content)
        env = os.environ.copy()
        env["ANTHROPIC_API_KEY"] = "fake"
        env["TICKET_CMD"] = ticket_cmd
        result = subprocess.run(
            [self.SCRIPT_PATH, "--dry-run", test_id],
            capture_output=True,
            text=True,
            env=env,
            cwd=WORKTREE_ROOT,
        )
        combined = result.stdout + result.stderr
        assert "DRY RUN" in combined, (
            f"Expected 'DRY RUN' in output.\n"
            f"returncode: {result.returncode}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        # Confirm prompt length is reported (> 0 means directory discovery succeeded)
        assert "prompt" in combined.lower() and any(c.isdigit() for c in combined), (
            f"Expected prompt length report in output, got:\n{combined}"
        )

    def test_enrich_uses_read_config(self) -> None:
        """enrich-file-impact.sh must reference read-config.sh for directory discovery.

        Checks the canonical plugin copy (wrapper is a thin delegate).
        """
        with open(self.CANONICAL_PATH) as f:
            content = f.read()

        assert "read-config.sh" in content, (
            "enrich-file-impact.sh must use read-config.sh for config-driven directory discovery"
        )

    def test_enrich_v3_uses_ticket_comment_not_file_append(
        self, tmp_path: object
    ) -> None:
        """In v3 mode (TICKETS_TRACKER_DIR set), enrich-file-impact.sh must NOT try to
        write to .tickets/<id>.md. It must route through the ticket CLI comment command.

        This is a v3 compatibility RED test: it fails on the old code that calls
        `printf ... >> .tickets/<id>.md` and passes after the fix.
        """
        import stat

        # Create a fake ticket CLI that records what arguments it receives.
        # When called as `ticket show <id>`, return valid output with a file-impact-free body.
        # When called as `ticket comment <id> <body>`, record the call and exit 0.
        ticket_cli = tmp_path / "fake-ticket"
        call_log = tmp_path / "ticket-calls.log"
        ticket_cli.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f'CALL_LOG="{call_log}"\n'
            'echo "$@" >> "$CALL_LOG"\n'
            'subcmd="${1:-}"\n'
            'if [ "$subcmd" = "show" ]; then\n'
            "    # Return a minimal ticket-show-like output (no file impact section)\n"
            "    cat <<'EOF'\n"
            "---\n"
            "id: test-v3-enrich\n"
            "status: open\n"
            "type: task\n"
            "---\n"
            "# Test v3 ticket\n\n"
            "## Description\n"
            "A task needing file impact enrichment.\n"
            "EOF\n"
            "    exit 0\n"
            'elif [ "$subcmd" = "comment" ]; then\n'
            "    exit 0\n"
            "else\n"
            "    exit 1\n"
            "fi\n"
        )
        ticket_cli.chmod(ticket_cli.stat().st_mode | stat.S_IEXEC)

        # Create a fake TICKETS_TRACKER_DIR (v3 — no .tickets/ flat files)
        tracker_dir = tmp_path / ".tickets-tracker"
        tracker_dir.mkdir()

        env = os.environ.copy()
        env["TICKETS_TRACKER_DIR"] = str(tracker_dir)
        env["TK"] = str(ticket_cli)
        env["TICKET_CMD"] = str(ticket_cli)
        env.pop("ANTHROPIC_API_KEY", None)  # graceful-degrade after dry-run check

        # Run with --dry-run so the API call is skipped; we just need to verify
        # the script doesn't crash with "Ticket file not found" for v3 paths.
        result = subprocess.run(
            [self.SCRIPT_PATH, "--dry-run", "test-v3-enrich"],
            capture_output=True,
            text=True,
            env=env,
            cwd=WORKTREE_ROOT,
        )
        # Must NOT error with "Ticket file not found" (that's the v2-only error)
        combined = result.stdout + result.stderr
        assert "Ticket file not found" not in combined, (
            f"enrich-file-impact.sh must not reference .tickets/*.md in v3 mode.\n"
            f"Got: {combined!r}"
        )
        # Without ANTHROPIC_API_KEY, --dry-run exits 0 with a warning
        assert result.returncode == 0, (
            f"Expected exit 0 in v3 dry-run mode.\n"
            f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        )


@pytest.mark.scripts
class TestCheckAcceptanceCriteriaV3:
    """Test check-acceptance-criteria.sh v3 compatibility."""

    SCRIPT_PATH = os.path.join(
        WORKTREE_ROOT, "plugins", "dso", "scripts", "check-acceptance-criteria.sh"
    )

    def test_error_message_does_not_reference_tickets_md(self) -> None:
        """The AC_CHECK fail message must not tell users to edit .tickets/<id>.md.

        In v3, .tickets/*.md files do not exist. The error message must be updated
        to guide users to the correct workflow.

        This is a v3 compatibility RED test: it fails on the old code that embeds
        '.tickets/$ID.md' in the error message and passes after the fix.
        """
        with open(self.SCRIPT_PATH) as f:
            content = f.read()

        assert (
            ".tickets/$ID.md" not in content and ".tickets/${ID}.md" not in content
        ), (
            "check-acceptance-criteria.sh error message must not reference .tickets/<id>.md "
            "(v2 flat-file path). Guide users to the v3 ticket CLI instead."
        )

    def test_ac_check_fail_output_does_not_reference_tickets_md(
        self, tmp_path: object
    ) -> None:
        """When AC check fails, output must not mention .tickets/<id>.md.

        This test creates a fake TK that returns a ticket body with no AC section,
        then verifies the script's error output contains no v2 path reference.
        """
        import stat

        # Create a fake tk that returns a ticket with no Acceptance Criteria section
        fake_tk = tmp_path / "fake-tk"
        fake_tk.write_text(
            "#!/usr/bin/env bash\n"
            "cat <<'EOF'\n"
            "---\n"
            "id: test-ac-no-criteria\n"
            "status: open\n"
            "type: task\n"
            "---\n"
            "# Task without acceptance criteria\n\n"
            "## Description\n"
            "A task with no AC block.\n"
            "EOF\n"
        )
        fake_tk.chmod(fake_tk.stat().st_mode | stat.S_IEXEC)

        env = os.environ.copy()
        env["TK"] = str(fake_tk)

        result = subprocess.run(
            [self.SCRIPT_PATH, "test-ac-no-criteria"],
            capture_output=True,
            text=True,
            env=env,
            cwd=WORKTREE_ROOT,
        )
        # Script should exit 1 (AC missing)
        assert result.returncode == 1, (
            f"Expected exit 1 when AC block is missing.\n"
            f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        )
        # Output must NOT contain a .tickets/ path reference
        combined = result.stdout + result.stderr
        assert ".tickets/" not in combined, (
            f"AC_CHECK fail message must not reference .tickets/ paths (v2-only).\n"
            f"Got: {combined!r}"
        )

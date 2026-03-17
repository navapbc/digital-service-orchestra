"""Tests for file impact section detection in issue-quality-check.sh and enrich-file-impact.sh."""

import os
import subprocess

import pytest

WORKTREE_ROOT = os.environ.get(
    "WORKTREE_ROOT",
    subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip(),
)


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

    SCRIPT_PATH = os.path.join(WORKTREE_ROOT, "scripts", "issue-quality-check.sh")

    def _create_ticket(self, tmpdir: str, ticket_id: str, content: str) -> str:
        """Create a mock ticket file and return path."""
        tickets_dir = os.path.join(tmpdir, ".tickets")
        os.makedirs(tickets_dir, exist_ok=True)
        path = os.path.join(tickets_dir, f"{ticket_id}.md")
        with open(path, "w") as f:
            f.write(content)
        return path

    def test_file_impact_section_contributes_to_quality_pass(
        self, tmp_path: object
    ) -> None:
        """A ticket with a file impact section should pass quality gate even without AC."""
        content = (
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
        self._create_ticket(str(tmp_path), "w21-mai8", content)
        # We test the awk pattern extraction indirectly by checking the script output
        # includes file_impact count. This requires the script to actually be updated.
        result = subprocess.run(
            [self.SCRIPT_PATH, "w21-mai8"],
            capture_output=True,
            text=True,
            cwd=WORKTREE_ROOT,
            env={**os.environ, "TICKETS_DIR": str(tmp_path / ".tickets")},
        )
        # w21-mai8 has a "### Files to modify" section, so it should be detected
        assert result.returncode == 0
        assert "file impact" in result.stdout.lower() or "FI" in result.stdout


@pytest.mark.scripts
class TestEnrichFileImpactScript:
    """Test enrich-file-impact.sh behavior."""

    SCRIPT_PATH = os.path.join(WORKTREE_ROOT, "scripts", "enrich-file-impact.sh")
    # Content-inspection tests use the canonical plugin copy (wrapper is thin)
    CANONICAL_PATH = os.path.join(WORKTREE_ROOT, "scripts", "enrich-file-impact.sh")

    def test_script_exists_and_is_executable(self) -> None:
        assert os.path.isfile(self.SCRIPT_PATH), "enrich-file-impact.sh must exist"
        assert os.access(self.SCRIPT_PATH, os.X_OK), (
            "enrich-file-impact.sh must be executable"
        )

    def test_exits_gracefully_without_api_key(self, tmp_path: object) -> None:
        """Without ANTHROPIC_API_KEY, script should exit 0 with warning."""
        # Use a temporary directory to avoid writing into the real .tickets/ dir,
        # which could trigger the PostToolUse ticket-sync-push hook.
        tmpdir = str(tmp_path)
        tickets_dir = os.path.join(tmpdir, ".tickets")
        os.makedirs(tickets_dir, exist_ok=True)
        test_id = "test-no-fi-001"
        ticket_path = os.path.join(tickets_dir, f"{test_id}.md")
        with open(ticket_path, "w") as f:
            f.write(
                "---\nid: test-no-fi-001\nstatus: open\n---\n"
                "# Test ticket without file impact\n\n"
                "## Description\nSome description here.\n"
            )
        env = os.environ.copy()
        env.pop("ANTHROPIC_API_KEY", None)
        # Point tk at the temp tickets dir so the script finds the ticket
        # without writing into the real .tickets/ directory.
        env["TICKETS_DIR"] = tickets_dir
        result = subprocess.run(
            [self.SCRIPT_PATH, "--dry-run", test_id],
            capture_output=True,
            text=True,
            env=env,
            cwd=WORKTREE_ROOT,
        )
        assert result.returncode == 0
        # Should mention missing API key
        combined = result.stdout + result.stderr
        assert "ANTHROPIC_API_KEY" in combined or "api key" in combined.lower()

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
        tickets_dir = tmp_path / ".tickets"
        tickets_dir.mkdir(parents=True)
        ticket_file = tickets_dir / "w21-mai8.md"
        ticket_file.write_text(
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
        result = subprocess.run(
            [self.SCRIPT_PATH, "--dry-run", "w21-mai8"],
            capture_output=True,
            text=True,
            cwd=WORKTREE_ROOT,
            env={**os.environ, "TICKETS_DIR": str(tmp_path / ".tickets")},
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
        tmpdir = str(tmp_path)
        tickets_dir = os.path.join(tmpdir, ".tickets")
        os.makedirs(tickets_dir, exist_ok=True)
        test_id = "test-dry-run-cfg"
        ticket_path = os.path.join(tickets_dir, f"{test_id}.md")
        with open(ticket_path, "w") as f:
            f.write(
                "---\nid: test-dry-run-cfg\nstatus: open\ntype: task\n---\n"
                "# Test ticket for dry-run config paths\n\n"
                "## Description\nA task that needs file impact enrichment.\n"
            )
        env = os.environ.copy()
        env["ANTHROPIC_API_KEY"] = "fake"
        env["TICKETS_DIR"] = tickets_dir
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

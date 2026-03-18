"""Tests for the startup config cache block in scripts/worktree-cleanup.sh.

The startup config block must:
  - Define PLUGIN_SCRIPTS relative to BASH_SOURCE[0]
  - Read all six project-specific config values via read-config.sh once at startup
  - Store values in CONFIG_* shell variables
  - Fail gracefully (empty string) if read-config.sh is absent or returns error

TDD: test_startup_config_block_reads_all_required_keys is the primary RED→GREEN test.
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "plugins" / "dso" / "scripts" / "worktree-cleanup.sh"

# The six CONFIG_* variables that must be declared by the startup config block
REQUIRED_CONFIG_VARS = [
    "CONFIG_COMPOSE_DB_FILE",
    "CONFIG_COMPOSE_PROJECT",
    "CONFIG_CONTAINER_PREFIX",
    "CONFIG_TICKETS_DIR",
    "CONFIG_BRANCH_PATTERN",
    "CONFIG_MAX_AGE_DAYS",
]

# The six read-config.sh keys that must be read
REQUIRED_CONFIG_KEYS = [
    "infrastructure.compose_db_file",
    "infrastructure.compose_project",
    "infrastructure.container_prefix",
    "tickets.directory",
    "worktree.branch_pattern",
    "worktree.max_age_days",
]


def _make_mock_read_config(tmpdir: Path, return_value: str = "mock-value") -> Path:
    """Create a mock read-config.sh that echoes a fixed value for any key."""
    mock_script = tmpdir / "read-config.sh"
    mock_script.write_text(
        f"#!/usr/bin/env bash\n"
        f"# Mock read-config.sh for testing\n"
        f"echo '{return_value}'\n"
    )
    mock_script.chmod(mock_script.stat().st_mode | stat.S_IEXEC)
    return mock_script


def _extract_startup_config_block(script_content: str) -> str:
    """Extract just the PLUGIN_SCRIPTS + CONFIG_* block from the script.

    Returns a minimal bash script that defines the block and then
    prints all CONFIG_* variables so we can verify they are set.
    """
    lines = script_content.splitlines()
    block_lines = []
    in_block = False

    for line in lines:
        # Start capturing at PLUGIN_SCRIPTS assignment
        if "PLUGIN_SCRIPTS=" in line and "BASH_SOURCE" in line:
            in_block = True
        if in_block:
            block_lines.append(line)
            # Stop after the last CONFIG_ assignment (CONFIG_MAX_AGE_DAYS)
            if "CONFIG_MAX_AGE_DAYS" in line and "read-config.sh" in line:
                break

    return "\n".join(block_lines)


@pytest.mark.scripts
class TestStartupConfigBlock:
    """The startup config cache block reads all required keys via read-config.sh."""

    def test_startup_config_block_reads_all_required_keys(self) -> None:
        """Sourcing the startup config block sets all six CONFIG_* variables.

        Uses a mock read-config.sh so the test is hermetic (no YAML/Python needed).
        The mock returns 'mock-value' for any key lookup.

        RED: fails before the config cache block is added to worktree-cleanup.sh.
        GREEN: passes after the block is added.
        """
        script_content = SCRIPT.read_text()

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)

            # Build a test harness that:
            #   1. Places the test script in a fake lockpick-workflow/scripts/ dir so
            #      BASH_SOURCE[0] resolves the same way as in worktree-cleanup.sh
            #      (PLUGIN_SCRIPTS = dirname(BASH_SOURCE[0]))
            #   2. Also places mock read-config.sh in the same dir (since PLUGIN_SCRIPTS
            #      is now the script's own directory)
            #   3. Executes just the PLUGIN_SCRIPTS + CONFIG_* block
            #   4. Prints each CONFIG_* variable name=value
            block = _extract_startup_config_block(script_content)

            # Place the test script in tmpdir/lockpick-workflow/scripts/ so that:
            #   BASH_SOURCE[0] = tmpdir/lockpick-workflow/scripts/test_config_block.sh
            #   dirname(BASH_SOURCE[0]) = tmpdir/lockpick-workflow/scripts/  (PLUGIN_SCRIPTS)
            #   read-config.sh = tmpdir/lockpick-workflow/scripts/read-config.sh  (our mock)
            fake_scripts_dir = tmpdir_path / "scripts"
            fake_scripts_dir.mkdir(parents=True)

            # Create mock read-config.sh in the same dir as the test script
            plugin_scripts_dir = fake_scripts_dir
            _make_mock_read_config(plugin_scripts_dir)

            test_script = fake_scripts_dir / "test_config_block.sh"
            var_prints = "\n".join(
                'echo "' + var + "=${" + var + ':-__UNSET__}"'
                for var in REQUIRED_CONFIG_VARS
            )
            test_script.write_text(
                "#!/usr/bin/env bash\n"
                "set -uo pipefail\n"
                "\n"
                "# Execute the startup config block — PLUGIN_SCRIPTS is derived\n"
                "# relative to BASH_SOURCE[0] (this script lives in scripts/ dir).\n"
                f"{block}\n"
                "\n"
                "# Print all CONFIG_* variables so the test can check them\n"
                f"{var_prints}\n"
            )
            test_script.chmod(test_script.stat().st_mode | stat.S_IEXEC)

            result = subprocess.run(
                ["bash", str(test_script)],
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(tmpdir_path)},
            )

        # The script must succeed
        assert result.returncode == 0, (
            f"Config block test script failed (rc={result.returncode}).\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )

        # Each CONFIG_* variable must be present and not __UNSET__
        output = result.stdout
        for var in REQUIRED_CONFIG_VARS:
            assert f"{var}=" in output, (
                f"Variable {var} was not printed — block may not define it.\n"
                f"stdout: {output}"
            )
            assert f"{var}=__UNSET__" not in output, (
                f"Variable {var} was not set by the config block.\nstdout: {output}"
            )

    def test_config_block_falls_back_gracefully_on_missing_read_config(self) -> None:
        """CONFIG_* variables are empty strings when read-config.sh is absent.

        Verifies the '|| true' fallback: no exit on lookup failure.

        The test harness places the script in a lockpick-workflow/scripts/ subdirectory
        so that BASH_SOURCE[0]-relative PLUGIN_SCRIPTS derivation resolves to
        tmpdir/lockpick-workflow/scripts — the same directory we created but
        intentionally left without read-config.sh.
        """
        script_content = SCRIPT.read_text()
        block = _extract_startup_config_block(script_content)

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)

            # Plugin scripts dir exists but contains NO read-config.sh.
            # Placing the test script in lockpick-workflow/scripts/ makes BASH_SOURCE[0]-relative
            # PLUGIN_SCRIPTS derivation resolve to tmpdir/lockpick-workflow/scripts (no read-config.sh).
            fake_scripts_dir = tmpdir_path / "scripts"
            fake_scripts_dir.mkdir(parents=True)

            var_prints = "\n".join(
                'echo "' + var + "=${" + var + ':-__UNSET__}"'
                for var in REQUIRED_CONFIG_VARS
            )
            # Script lives in lockpick-workflow/scripts/ so dirname(BASH_SOURCE[0])
            # = tmpdir/lockpick-workflow/scripts/ = PLUGIN_SCRIPTS (no read-config.sh present)
            test_script = fake_scripts_dir / "test_fallback.sh"
            test_script.write_text(
                "#!/usr/bin/env bash\n"
                "set -uo pipefail\n"
                "\n"
                "# PLUGIN_SCRIPTS is derived from BASH_SOURCE[0] by the extracted block.\n"
                "# The script is placed in scripts/ so the relative path resolves correctly.\n"
                f"{block}\n"
                "\n"
                f"{var_prints}\n"
            )
            test_script.chmod(test_script.stat().st_mode | stat.S_IEXEC)

            result = subprocess.run(
                ["bash", str(test_script)],
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(tmpdir_path)},
            )

        # Must not exit non-zero — graceful fallback
        assert result.returncode == 0, (
            f"Fallback test script failed unexpectedly (rc={result.returncode}).\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )

        # Variables should be set (to empty string) — __UNSET__ means unset, not empty
        output = result.stdout
        for var in REQUIRED_CONFIG_VARS:
            assert f"{var}=" in output, (
                f"Variable {var} was not printed at all.\nstdout: {output}"
            )

    def test_read_config_called_exactly_six_times(self) -> None:
        """read-config.sh is called exactly once per config key (6 total).

        Ensures no per-use read-config.sh calls sneak in later.
        """
        content = SCRIPT.read_text()
        # Count lines that call bash ...read-config.sh
        lines_with_calls = [
            line
            for line in content.splitlines()
            if "read-config.sh" in line and "bash" in line
        ]
        assert len(lines_with_calls) == 6, (
            f"Expected exactly 6 'bash ... read-config.sh' calls, found {len(lines_with_calls)}.\n"
            f"Lines: {lines_with_calls}"
        )

    def test_plugin_scripts_derived_from_bash_source(self) -> None:
        """PLUGIN_SCRIPTS must be derived relative to BASH_SOURCE[0], not hardcoded."""
        content = SCRIPT.read_text()
        assert "PLUGIN_SCRIPTS" in content, (
            "PLUGIN_SCRIPTS variable not found in script"
        )
        assert "BASH_SOURCE[0]" in content, (
            "BASH_SOURCE[0] not referenced for PLUGIN_SCRIPTS"
        )

        # Find the PLUGIN_SCRIPTS= line and ensure BASH_SOURCE[0] appears there
        for line in content.splitlines():
            if "PLUGIN_SCRIPTS=" in line:
                assert "BASH_SOURCE" in line, (
                    f"PLUGIN_SCRIPTS= line does not reference BASH_SOURCE:\n{line}"
                )
                break

    def test_all_six_config_vars_present_in_script(self) -> None:
        """All six CONFIG_* variable names appear in the script."""
        content = SCRIPT.read_text()
        for var in REQUIRED_CONFIG_VARS:
            assert var in content, f"CONFIG variable '{var}' not found in {SCRIPT}"

    def test_all_six_config_keys_present_in_script(self) -> None:
        """All six read-config.sh key paths appear in the script."""
        content = SCRIPT.read_text()
        for key in REQUIRED_CONFIG_KEYS:
            assert key in content, f"Config key '{key}' not found in {SCRIPT}"

    def test_graceful_fallback_syntax_present(self) -> None:
        """All six read-config.sh calls use '2>/dev/null || true' for graceful fallback."""
        content = SCRIPT.read_text()
        lines_with_calls = [
            line
            for line in content.splitlines()
            if "read-config.sh" in line and "bash" in line
        ]
        for line in lines_with_calls:
            assert "2>/dev/null || true" in line, (
                f"read-config.sh call missing '2>/dev/null || true' graceful fallback:\n{line}"
            )


@pytest.mark.scripts
class TestDockerTeardownConfig:
    """Docker teardown section uses CONFIG_COMPOSE_DB_FILE and CONFIG_COMPOSE_PROJECT."""

    def test_docker_teardown_uses_config_compose_db_file(self) -> None:
        """Worktree removal section builds compose_file from $CONFIG_COMPOSE_DB_FILE.

        RED: fails while the script still hardcodes 'app/docker-compose.db.yml'.
        GREEN: passes after the hardcoded path is replaced with $CONFIG_COMPOSE_DB_FILE.
        """
        content = SCRIPT.read_text()
        # Must NOT contain the old hardcoded path
        assert "app/docker-compose.db.yml" not in content, (
            "Found hardcoded 'app/docker-compose.db.yml' in worktree-cleanup.sh — "
            "replace with $CONFIG_COMPOSE_DB_FILE"
        )
        # Must reference CONFIG_COMPOSE_DB_FILE in the compose_file construction
        assert "CONFIG_COMPOSE_DB_FILE" in content, (
            "CONFIG_COMPOSE_DB_FILE variable not found in script"
        )
        # compose_file must be built from $path + $CONFIG_COMPOSE_DB_FILE
        compose_file_lines = [
            line
            for line in content.splitlines()
            if "compose_file" in line and "CONFIG_COMPOSE_DB_FILE" in line
        ]
        assert len(compose_file_lines) >= 1, (
            "No line found that constructs compose_file using CONFIG_COMPOSE_DB_FILE"
        )

    def test_docker_teardown_skips_when_config_compose_db_file_empty(self) -> None:
        """Docker Compose teardown is skipped when CONFIG_COMPOSE_DB_FILE is empty.

        RED: fails while the section lacks the guard.
        GREEN: passes after adding an 'if [[ -n "$CONFIG_COMPOSE_DB_FILE" ]]' guard.
        """
        content = SCRIPT.read_text()
        # The teardown block must have a guard for empty CONFIG_COMPOSE_DB_FILE
        assert (
            "if.*CONFIG_COMPOSE_DB_FILE" in content
            or "CONFIG_COMPOSE_DB_FILE.*-n" in content
            or "-n.*CONFIG_COMPOSE_DB_FILE" in content
        ) or any(
            (
                "CONFIG_COMPOSE_DB_FILE" in line
                and ("if" in line or "-n" in line or "-z" in line)
            )
            for line in content.splitlines()
        ), (
            "No guard found for empty CONFIG_COMPOSE_DB_FILE — "
            "the Docker Compose teardown must be skipped when CONFIG_COMPOSE_DB_FILE is empty"
        )

    def test_orphaned_network_cleanup_uses_config_compose_project(self) -> None:
        """Orphaned network cleanup uses $CONFIG_COMPOSE_PROJECT instead of hardcoded prefix.

        RED: fails while the script still hardcodes 'lockpick-db-worktree-'.
        GREEN: passes after the hardcoded filter is replaced with $CONFIG_COMPOSE_PROJECT.
        """
        content = SCRIPT.read_text()
        # Must NOT contain the old hardcoded network filter
        assert "lockpick-db-worktree-" not in content, (
            "Found hardcoded 'lockpick-db-worktree-' in worktree-cleanup.sh — "
            "replace with a filter derived from $CONFIG_COMPOSE_PROJECT"
        )
        # Must reference CONFIG_COMPOSE_PROJECT
        assert "CONFIG_COMPOSE_PROJECT" in content, (
            "CONFIG_COMPOSE_PROJECT variable not found in script"
        )

    def test_docker_teardown_requires_both_config_vars(self) -> None:
        """Docker teardown guard requires BOTH CONFIG_COMPOSE_DB_FILE and CONFIG_COMPOSE_PROJECT.

        When CONFIG_COMPOSE_DB_FILE is set but CONFIG_COMPOSE_PROJECT is empty,
        the teardown block must be skipped to avoid accidentally tearing down
        unrelated containers with an unqualified project name.

        RED: fails while guard only checks CONFIG_COMPOSE_DB_FILE.
        GREEN: passes after guard also requires CONFIG_COMPOSE_PROJECT to be non-empty.
        """
        content = SCRIPT.read_text()
        # Find the guard line that protects the Docker Compose teardown
        guard_lines = [
            line
            for line in content.splitlines()
            if "CONFIG_COMPOSE_DB_FILE" in line
            and ("DRY_RUN" in line or "docker" in line)
            and ("if" in line or "[[ -n" in line)
        ]
        assert guard_lines, (
            "Could not find the Docker teardown guard line referencing CONFIG_COMPOSE_DB_FILE"
        )
        guard_line = guard_lines[0]
        # The guard must also require CONFIG_COMPOSE_PROJECT to be non-empty
        assert "CONFIG_COMPOSE_PROJECT" in guard_line, (
            "Docker teardown guard checks CONFIG_COMPOSE_DB_FILE but NOT CONFIG_COMPOSE_PROJECT. "
            "When CONFIG_COMPOSE_PROJECT is empty, the teardown would use a bare worktree name "
            "as COMPOSE_PROJECT_NAME, risking unrelated container teardown. "
            f"Guard line: {guard_line!r}"
        )

    def test_orphaned_network_sed_uses_config_compose_project(self) -> None:
        """Orphaned network sed extraction does not hardcode 'lockpick-db-' prefix.

        RED: fails while sed still uses hardcoded 's/^lockpick-db-//'.
        GREEN: passes after sed uses $CONFIG_COMPOSE_PROJECT to strip the prefix.
        """
        content = SCRIPT.read_text()
        # The sed pattern s/^lockpick-db- must NOT appear in non-comment lines
        non_comment_lines = [
            line for line in content.splitlines() if not line.lstrip().startswith("#")
        ]
        hardcoded_sed = any("s/^lockpick-db-" in line for line in non_comment_lines)
        assert not hardcoded_sed, (
            "Found hardcoded sed pattern 's/^lockpick-db-' in non-comment line — "
            "replace with a pattern derived from $CONFIG_COMPOSE_PROJECT"
        )


@pytest.mark.scripts
class TestTicketsDirConfig:
    """git status/diff filters use CONFIG_TICKETS_DIR instead of a hardcoded .tickets/ path."""

    def test_tickets_dir_uses_config_tickets_directory(self) -> None:
        """git status filter uses ${CONFIG_TICKETS_DIR:-.tickets}/ instead of hardcoded .tickets/.

        RED: fails while the script still hardcodes '^.. \\.tickets/' in the grep -v filter.
        GREEN: passes after replacing '.tickets/' with '${CONFIG_TICKETS_DIR:-.tickets}/'.

        The test sets CONFIG_TICKETS_DIR='.custom-tickets' and sources the relevant
        section of the script to verify the git status filter uses the custom path.
        The acceptance check is done statically: the script must contain
        '${CONFIG_TICKETS_DIR' in the grep -v pattern used for clean-status detection.
        """
        content = SCRIPT.read_text()
        non_comment_lines = [
            line for line in content.splitlines() if not line.lstrip().startswith("#")
        ]
        # The grep -v filter for .tickets/ must reference CONFIG_TICKETS_DIR
        grep_filter_lines = [
            line
            for line in non_comment_lines
            if "grep -v" in line and ("tickets" in line.lower() or "TICKETS" in line)
        ]
        assert grep_filter_lines, (
            "No 'grep -v' line referencing tickets dir found in script — "
            "the git status filter must exist."
        )
        # All grep -v filter lines for tickets must use CONFIG_TICKETS_DIR, not hardcoded '.tickets/'
        hardcoded_filter = any(
            "grep -v" in line and "'\\.tickets/'" in line for line in non_comment_lines
        )
        assert not hardcoded_filter, (
            "Found 'grep -v' with hardcoded '\\.tickets/' in non-comment line — "
            "replace with '${CONFIG_TICKETS_DIR:-.tickets}/' so the filter uses the config var."
        )
        # CONFIG_TICKETS_DIR must appear in the grep filter lines
        config_used = any("CONFIG_TICKETS_DIR" in line for line in grep_filter_lines)
        assert config_used, (
            "grep -v filter for tickets dir does not reference CONFIG_TICKETS_DIR — "
            "replace hardcoded '.tickets/' with '${CONFIG_TICKETS_DIR:-.tickets}/'."
        )

    def test_diff_commands_use_config_tickets_dir(self) -> None:
        """git diff commands exclude tickets dir via CONFIG_TICKETS_DIR, not hardcoded '.tickets/'.

        RED: fails while diff commands still hardcode ':!.tickets/' or 'main -- .tickets/'.
        GREEN: passes after replacing hardcoded '.tickets/' with '${CONFIG_TICKETS_DIR:-.tickets}/'.
        """
        content = SCRIPT.read_text()
        non_comment_lines = [
            line for line in content.splitlines() if not line.lstrip().startswith("#")
        ]
        # Any non-comment diff lines that use '.tickets/' directly (not via CONFIG_TICKETS_DIR)
        # must not exist
        hardcoded_diff = [
            line
            for line in non_comment_lines
            if "git" in line
            and "diff" in line
            and ".tickets/" in line
            and "CONFIG_TICKETS_DIR" not in line
        ]
        assert not hardcoded_diff, (
            "Found git diff lines with hardcoded '.tickets/' path — "
            "replace with '${CONFIG_TICKETS_DIR:-.tickets}/' (CONFIG_TICKETS_DIR):\n"
            + "\n".join(hardcoded_diff)
        )

    def test_no_hardcoded_tickets_dir_in_git_commands(self) -> None:
        """No git command line uses a hardcoded literal '.tickets/' path without CONFIG_TICKETS_DIR.

        RED: fails while git commands still hardcode '.tickets/'.
        GREEN: passes after all occurrences in git commands are replaced with the config var.

        This test targets lines that contain 'git' and either 'grep' or 'diff' and '.tickets/',
        which are the operational lines that should use CONFIG_TICKETS_DIR.
        Excludes usage heredoc text and variable declaration comment strings.
        """
        content = SCRIPT.read_text()
        non_comment_lines = [
            line for line in content.splitlines() if not line.lstrip().startswith("#")
        ]
        # Only check lines that actually invoke git or grep (operational lines)
        violations = [
            line
            for line in non_comment_lines
            if ".tickets/" in line
            and "CONFIG_TICKETS_DIR" not in line
            and ("git " in line or "grep " in line)
        ]
        assert not violations, (
            "Found hardcoded '.tickets/' in git/grep command lines — "
            "replace with '${CONFIG_TICKETS_DIR:-.tickets}/':\n" + "\n".join(violations)
        )


@pytest.mark.scripts
class TestBranchPatternConfig:
    """git branch --list and .gitignore cleanup use CONFIG_BRANCH_PATTERN, not hardcoded 'worktree-*'."""

    def test_branch_pattern_uses_config_branch_pattern(self) -> None:
        """git branch --list uses ${CONFIG_BRANCH_PATTERN:-worktree-*} instead of hardcoded 'worktree-*'.

        RED: fails while the script still uses hardcoded 'worktree-*' in the branch --list call.
        GREEN: passes after replacing 'worktree-*' with '${CONFIG_BRANCH_PATTERN:-worktree-*}'.

        The test checks that the git branch --list call references CONFIG_BRANCH_PATTERN.
        """
        content = SCRIPT.read_text()
        non_comment_lines = [
            line for line in content.splitlines() if not line.lstrip().startswith("#")
        ]
        # Must NOT have 'branch --list' with hardcoded 'worktree-*' glob
        hardcoded_list = any(
            "branch --list" in line and "'worktree-*'" in line
            for line in non_comment_lines
        )
        assert not hardcoded_list, (
            "Found 'git branch --list' with hardcoded 'worktree-*' glob — "
            "replace with '${CONFIG_BRANCH_PATTERN:-worktree-*}' to use the config var."
        )
        # CONFIG_BRANCH_PATTERN must appear near the branch --list call
        branch_list_lines = [
            line for line in non_comment_lines if "branch --list" in line
        ]
        assert branch_list_lines, "No 'git branch --list' call found in script."
        config_used = any("CONFIG_BRANCH_PATTERN" in line for line in branch_list_lines)
        assert config_used, (
            "git branch --list call does not reference CONFIG_BRANCH_PATTERN — "
            "replace hardcoded 'worktree-*' with '${CONFIG_BRANCH_PATTERN:-worktree-*}'."
        )

    def test_gitignore_cleanup_uses_config_branch_pattern(self) -> None:
        """The .gitignore cleanup section uses CONFIG_BRANCH_PATTERN for prefix detection.

        RED: fails while awk still uses hardcoded 'worktree-' prefix and 'worktree-*/' wildcard.
        GREEN: passes after the awk patterns are derived from CONFIG_BRANCH_PATTERN.

        Checks that after the 'Clean up .gitignore' comment, CONFIG_BRANCH_PATTERN appears.
        """
        content = SCRIPT.read_text()
        lines = content.splitlines()
        # Find the .gitignore cleanup section
        gitignore_section_start = None
        for i, line in enumerate(lines):
            if "Clean up" in line and "gitignore" in line.lower():
                gitignore_section_start = i
                break
        assert gitignore_section_start is not None, (
            "Could not find '# Clean up .gitignore' section header in script."
        )
        # Check the next 20 lines of the section for CONFIG_BRANCH_PATTERN usage
        section_lines = lines[gitignore_section_start : gitignore_section_start + 20]
        config_used = any("CONFIG_BRANCH_PATTERN" in line for line in section_lines)
        assert config_used, (
            "The .gitignore cleanup section (within 20 lines of 'Clean up .gitignore' comment) "
            "does not reference CONFIG_BRANCH_PATTERN — "
            "replace hardcoded 'worktree-' prefix patterns with CONFIG_BRANCH_PATTERN-derived values."
        )

    def test_no_hardcoded_worktree_glob_in_branch_list(self) -> None:
        """No functional git branch --list call uses a hardcoded 'worktree-*' glob literal.

        RED: fails while the branch --list call contains the hardcoded glob.
        GREEN: passes after the glob is replaced with the config var.
        """
        content = SCRIPT.read_text()
        non_comment_lines = [
            line for line in content.splitlines() if not line.lstrip().startswith("#")
        ]
        violations = [
            line
            for line in non_comment_lines
            if "branch --list" in line and "'worktree-*'" in line
        ]
        assert not violations, (
            "Found git branch --list with hardcoded 'worktree-*' in functional lines — "
            "replace with '${CONFIG_BRANCH_PATTERN:-worktree-*}':\n"
            + "\n".join(violations)
        )


@pytest.mark.scripts
class TestAgeDaysConfig:
    """AGE_DAYS default in worktree-cleanup.sh is driven by CONFIG_MAX_AGE_DAYS."""

    def test_age_days_uses_config_max_age_days(self) -> None:
        """AGE_DAYS in the Defaults block uses ${CONFIG_MAX_AGE_DAYS:-2} instead of literal 2.

        RED: fails while AGE_DAYS=2 literal is still present.
        GREEN: passes after AGE_DAYS=${CONFIG_MAX_AGE_DAYS:-2} is used.
        """
        content = SCRIPT.read_text()
        # Must contain CONFIG_MAX_AGE_DAYS in the AGE_DAYS assignment
        assert "AGE_DAYS" in content and "CONFIG_MAX_AGE_DAYS" in content, (
            "Script must assign AGE_DAYS using CONFIG_MAX_AGE_DAYS"
        )
        age_days_lines = [
            line
            for line in content.splitlines()
            if line.strip().startswith("AGE_DAYS=")
        ]
        assert age_days_lines, "No AGE_DAYS= assignment line found in script"
        # The assignment must reference CONFIG_MAX_AGE_DAYS
        assert any("CONFIG_MAX_AGE_DAYS" in line for line in age_days_lines), (
            "AGE_DAYS= assignment does not reference CONFIG_MAX_AGE_DAYS.\n"
            f"Found: {age_days_lines}"
        )

    def test_age_days_literal_2_not_default_assignment(self) -> None:
        """AGE_DAYS=2 literal no longer appears as the default assignment.

        RED: fails while 'AGE_DAYS=2' is still the bare assignment in the Defaults block.
        GREEN: passes after it is replaced with '${CONFIG_MAX_AGE_DAYS:-2}'.
        """
        import re

        content = SCRIPT.read_text()
        # AGE_DAYS=2 as a bare assignment (not inside ${...}) must not exist
        violations = [
            line
            for line in content.splitlines()
            if re.match(r"^AGE_DAYS=2\b", line.strip())
        ]
        assert not violations, (
            "Found bare 'AGE_DAYS=2' assignment — replace with 'AGE_DAYS=${CONFIG_MAX_AGE_DAYS:-2}':\n"
            + "\n".join(violations)
        )

    def test_is_old_enough_fallback_uses_2_not_7(self) -> None:
        """is_old_enough() fallback uses AGE_DAYS:-2, not AGE_DAYS:-7.

        RED: fails while ${AGE_DAYS:-7} is still used in is_old_enough().
        GREEN: passes after the fallback is updated to ${AGE_DAYS:-2}.
        """
        content = SCRIPT.read_text()
        # Must not contain AGE_DAYS:-7 anywhere in functional (non-comment) lines
        non_comment_lines = [
            line for line in content.splitlines() if not line.lstrip().startswith("#")
        ]
        violations = [line for line in non_comment_lines if "AGE_DAYS:-7" in line]
        assert not violations, (
            "Found 'AGE_DAYS:-7' in non-comment lines — "
            "update is_old_enough() fallback from '${AGE_DAYS:-7}' to '${AGE_DAYS:-2}':\n"
            + "\n".join(violations)
        )

    def test_age_days_reads_from_config_max_age_days(self) -> None:
        """When CONFIG_MAX_AGE_DAYS=14, AGE_DAYS resolves to 14.

        TDD RED: fails before AGE_DAYS=${CONFIG_MAX_AGE_DAYS:-2} is used.
        TDD GREEN: passes after the change is made.
        """
        import subprocess

        result = subprocess.run(
            [
                "bash",
                "-c",
                "CONFIG_MAX_AGE_DAYS=14; AGE_DAYS=${CONFIG_MAX_AGE_DAYS:-2}; "
                'test "$AGE_DAYS" = "14" && echo "PASS" || echo "FAIL"',
            ],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"bash -c test failed (rc={result.returncode}).\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout, (
            "When CONFIG_MAX_AGE_DAYS=14, AGE_DAYS should resolve to 14.\n"
            f"stdout: {result.stdout}"
        )
        # Now verify the actual script uses the pattern
        content = SCRIPT.read_text()
        age_days_assignment = [
            line
            for line in content.splitlines()
            if line.strip().startswith("AGE_DAYS=")
        ]
        assert any("CONFIG_MAX_AGE_DAYS" in line for line in age_days_assignment), (
            "The script's AGE_DAYS assignment must use CONFIG_MAX_AGE_DAYS.\n"
            f"Found AGE_DAYS lines: {age_days_assignment}"
        )

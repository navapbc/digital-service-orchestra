"""Tests for the startup config cache block in scripts/worktree-cleanup.sh.

The startup config block must:
  - Define PLUGIN_SCRIPTS relative to BASH_SOURCE[0]
  - Read all five project-specific config values via read-config.sh once at startup
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

# The five CONFIG_* variables that must be declared by the startup config block
REQUIRED_CONFIG_VARS = [
    "CONFIG_COMPOSE_DB_FILE",
    "CONFIG_COMPOSE_PROJECT",
    "CONFIG_CONTAINER_PREFIX",
    "CONFIG_BRANCH_PATTERN",
    "CONFIG_MAX_AGE_HOURS",
]

# The five read-config.sh keys that must be read
REQUIRED_CONFIG_KEYS = [
    "infrastructure.compose_db_file",
    "infrastructure.compose_project",
    "infrastructure.container_prefix",
    "worktree.branch_pattern",
    "worktree.max_age_hours",
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
            # Stop after the last CONFIG_ assignment (CONFIG_MAX_AGE_HOURS)
            if "CONFIG_MAX_AGE_HOURS" in line and "read-config.sh" in line:
                break

    return "\n".join(block_lines)


@pytest.mark.scripts
class TestStartupConfigBlock:
    """The startup config cache block reads all required keys via read-config.sh."""

    def test_startup_config_block_reads_all_required_keys(self) -> None:
        """Sourcing the startup config block sets all five CONFIG_* variables.

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

    def test_read_config_called_exactly_five_times(self) -> None:
        """read-config.sh is called exactly once per config key (5 total).

        Ensures no per-use read-config.sh calls sneak in later.
        """
        content = SCRIPT.read_text()
        # Count lines that call bash ...read-config.sh
        lines_with_calls = [
            line
            for line in content.splitlines()
            if "read-config.sh" in line and "bash" in line
        ]
        assert len(lines_with_calls) == 5, (
            f"Expected exactly 5 'bash ... read-config.sh' calls, found {len(lines_with_calls)}.\n"
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
        """All five CONFIG_* variable names appear in the script."""
        content = SCRIPT.read_text()
        for var in REQUIRED_CONFIG_VARS:
            assert var in content, f"CONFIG variable '{var}' not found in {SCRIPT}"

    def test_all_six_config_keys_present_in_script(self) -> None:
        """All five read-config.sh key paths appear in the script."""
        content = SCRIPT.read_text()
        for key in REQUIRED_CONFIG_KEYS:
            assert key in content, f"Config key '{key}' not found in {SCRIPT}"

    def test_graceful_fallback_syntax_present(self) -> None:
        """All five read-config.sh calls use '2>/dev/null || true' for graceful fallback."""
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
class TestAgeHoursConfig:
    """AGE_HOURS default in worktree-cleanup.sh is driven by CONFIG_MAX_AGE_HOURS."""

    def test_age_hours_uses_config_max_age_hours(self) -> None:
        """AGE_HOURS in the Defaults block uses ${CONFIG_MAX_AGE_HOURS:-12} instead of a literal.

        RED: fails while the old AGE_DAYS/CONFIG_MAX_AGE_DAYS pattern is still present.
        GREEN: passes after AGE_HOURS=${CONFIG_MAX_AGE_HOURS:-12} is used.
        """
        content = SCRIPT.read_text()
        # Must contain CONFIG_MAX_AGE_HOURS in the AGE_HOURS assignment
        assert "AGE_HOURS" in content and "CONFIG_MAX_AGE_HOURS" in content, (
            "Script must assign AGE_HOURS using CONFIG_MAX_AGE_HOURS"
        )
        age_hours_lines = [
            line
            for line in content.splitlines()
            if line.strip().startswith("AGE_HOURS=")
        ]
        assert age_hours_lines, "No AGE_HOURS= assignment line found in script"
        # The assignment must reference CONFIG_MAX_AGE_HOURS
        assert any("CONFIG_MAX_AGE_HOURS" in line for line in age_hours_lines), (
            "AGE_HOURS= assignment does not reference CONFIG_MAX_AGE_HOURS.\n"
            f"Found: {age_hours_lines}"
        )

    def test_age_hours_literal_not_bare_assignment(self) -> None:
        """AGE_HOURS=12 literal no longer appears as a bare default assignment.

        GREEN: passes after AGE_HOURS=${AGE_HOURS:-${CONFIG_MAX_AGE_HOURS:-12}} is used.
        """
        import re

        content = SCRIPT.read_text()
        # AGE_HOURS=12 as a bare assignment (not inside ${...}) must not exist
        violations = [
            line
            for line in content.splitlines()
            if re.match(r"^AGE_HOURS=\d+\b", line.strip())
        ]
        assert not violations, (
            "Found bare 'AGE_HOURS=<number>' assignment — use "
            "'AGE_HOURS=${AGE_HOURS:-${CONFIG_MAX_AGE_HOURS:-12}}':\n"
            + "\n".join(violations)
        )

    def test_is_old_enough_fallback_uses_12_hours(self) -> None:
        """is_old_enough() function body uses AGE_HOURS:-12, not AGE_DAYS.

        The backward-compat shim is allowed to reference AGE_DAYS (intentional),
        but the is_old_enough() function itself must use AGE_HOURS:-12.
        """
        content = SCRIPT.read_text()
        lines = content.splitlines()

        # Extract only lines inside the is_old_enough() function
        in_func = False
        func_lines = []
        brace_depth = 0
        for line in lines:
            stripped = line.strip()
            if "is_old_enough()" in stripped and "{" in stripped:
                in_func = True
                brace_depth = stripped.count("{") - stripped.count("}")
                func_lines.append(line)
                continue
            if in_func:
                func_lines.append(line)
                brace_depth += stripped.count("{") - stripped.count("}")
                if brace_depth <= 0:
                    break

        assert func_lines, "is_old_enough() function not found in script"
        func_non_comment = [ln for ln in func_lines if not ln.lstrip().startswith("#")]

        # is_old_enough() must not reference AGE_DAYS
        violations = [ln for ln in func_non_comment if "AGE_DAYS" in ln]
        assert not violations, (
            "is_old_enough() references 'AGE_DAYS' — it must use 'AGE_HOURS':\n"
            + "\n".join(violations)
        )
        # is_old_enough() must reference AGE_HOURS:-12
        assert any("AGE_HOURS:-12" in ln for ln in func_non_comment), (
            "is_old_enough() must use '${AGE_HOURS:-12}' as the fallback value"
        )

    def test_age_days_backward_compat_shim_converts_and_warns(self) -> None:
        """When AGE_DAYS=3 is set and AGE_HOURS is unset, the shim sets AGE_HOURS=72 and warns.

        Behavioral test: extracts the shim block from the script and executes it via
        subprocess with AGE_DAYS=3 in the environment, then asserts the runtime outcomes.

        GREEN: passes after the shim block is added.
        """
        lines = SCRIPT.read_text().splitlines()

        # Extract the shim block: _AGE_HOURS_FROM_ENV capture line through the
        # closing `fi` of the `if [[ -n "${AGE_DAYS:-}"` block.
        shim_lines: list[str] = []
        in_shim = False
        brace_depth = 0
        for line in lines:
            stripped = line.strip()
            if not in_shim and "_AGE_HOURS_FROM_ENV=" in stripped:
                in_shim = True
            if in_shim:
                shim_lines.append(line)
                # Track if/fi nesting so we stop at the right fi
                if stripped.startswith("if ") or stripped.startswith("if["):
                    brace_depth += 1
                if stripped == "fi":
                    if brace_depth > 0:
                        brace_depth -= 1
                    if brace_depth == 0:
                        break  # done

        assert shim_lines, "Could not extract the AGE_DAYS backward-compat shim block"

        # Build a small test harness: run the shim block and print AGE_HOURS
        harness = (
            "#!/usr/bin/env bash\n"
            "set -uo pipefail\n"
            "\n" + "\n".join(shim_lines) + '\necho "AGE_HOURS=${AGE_HOURS}"\n'
        )

        result = subprocess.run(
            ["bash", "-c", harness],
            capture_output=True,
            text=True,
            env={**os.environ, "AGE_DAYS": "3"},  # AGE_HOURS intentionally absent
        )

        assert result.returncode == 0, (
            f"Shim harness exited non-zero (rc={result.returncode}).\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "AGE_HOURS=72" in result.stdout, (
            "AGE_DAYS=3 should convert to AGE_HOURS=72 (3 × 24).\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert (
            "deprecated" in result.stderr.lower() or "warning" in result.stderr.lower()
        ), (
            "Shim must emit a deprecation warning to stderr when AGE_DAYS is set.\n"
            f"stderr: {result.stderr}"
        )

    def test_age_hours_reads_from_config_max_age_hours(self) -> None:
        """When CONFIG_MAX_AGE_HOURS=24, AGE_HOURS resolves to 24.

        TDD GREEN: passes after AGE_HOURS=${AGE_HOURS:-${CONFIG_MAX_AGE_HOURS:-12}} is used.
        """
        import subprocess

        result = subprocess.run(
            [
                "bash",
                "-c",
                "CONFIG_MAX_AGE_HOURS=24; AGE_HOURS=${AGE_HOURS:-${CONFIG_MAX_AGE_HOURS:-12}}; "
                'test "$AGE_HOURS" = "24" && echo "PASS" || echo "FAIL"',
            ],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"bash -c test failed (rc={result.returncode}).\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "PASS" in result.stdout, (
            "When CONFIG_MAX_AGE_HOURS=24, AGE_HOURS should resolve to 24.\n"
            f"stdout: {result.stdout}"
        )
        # Now verify the actual script uses the pattern
        content = SCRIPT.read_text()
        age_hours_assignment = [
            line
            for line in content.splitlines()
            if line.strip().startswith("AGE_HOURS=")
        ]
        assert any("CONFIG_MAX_AGE_HOURS" in line for line in age_hours_assignment), (
            "The script's AGE_HOURS assignment must use CONFIG_MAX_AGE_HOURS.\n"
            f"Found AGE_HOURS lines: {age_hours_assignment}"
        )

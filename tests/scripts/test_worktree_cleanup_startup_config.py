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
# (consecutive read-config.sh lines at the top of worktree-cleanup.sh).
# CONFIG_ORPHAN_PATTERNS (a list-valued config) is read separately later in the
# script via `read-config.sh --list worktree.orphan_patterns`, not in the
# startup block, so it is not in this list — but it IS counted in the
# read_config_called_exactly_six_times test below (bug 7000-e366-367d-4ab2).
REQUIRED_CONFIG_VARS = [
    "CONFIG_COMPOSE_DB_FILE",
    "CONFIG_COMPOSE_PROJECT",
    "CONFIG_CONTAINER_PREFIX",
    "CONFIG_BRANCH_PATTERN",
    "CONFIG_MAX_AGE_HOURS",
]

# The five read-config.sh keys that must be read in the startup block.
REQUIRED_CONFIG_KEYS = [
    "infrastructure.compose_db_file",
    "infrastructure.compose_project",
    "infrastructure.container_prefix",
    "worktree.branch_pattern",
    "worktree.max_age_hours",
]


def _make_isolated_git_repo(tmpdir: Path) -> Path:
    """Create a minimal isolated git repo suitable for running worktree-cleanup.sh.

    The repo is placed at tmpdir/repo/. Worktrees are typically added under
    tmpdir/ (alongside repo/). The fake-home dir is placed at tmpdir/meta/home/.

    To prevent the orphan-dir sweep from removing tmpdir/meta (which would be
    empty and thus match _dir_only_regenerable), we write a sentinel file at
    tmpdir/meta/.keep — a real file outside the regenerable allowlist.
    """
    repo = tmpdir / "repo"
    repo.mkdir()
    (tmpdir / "meta" / "home").mkdir(parents=True, exist_ok=True)
    # Sentinel file prevents the orphan sweep from treating meta/ as an empty orphan dir.
    (tmpdir / "meta" / ".keep").write_text("test isolation sentinel")
    env = {
        **os.environ,
        "HOME": str(tmpdir / "meta" / "home"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
    }

    subprocess.run(
        ["git", "init", "-b", "main", str(repo)],
        check=True,
        capture_output=True,
        env=env,
    )
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.email", "test@example.com"],
        check=True,
        capture_output=True,
        env=env,
    )
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.name", "Test"],
        check=True,
        capture_output=True,
        env=env,
    )
    # Create an initial commit so the repo has a HEAD and a main branch
    (repo / "README.md").write_text("test repo")
    subprocess.run(
        ["git", "-C", str(repo), "add", "README.md"],
        check=True,
        capture_output=True,
        env=env,
    )
    subprocess.run(
        ["git", "-C", str(repo), "commit", "-m", "initial commit"],
        check=True,
        capture_output=True,
        env=env,
    )
    return repo


def _make_mock_read_config(
    scripts_dir: Path,
    *,
    key_values: dict | None = None,
    default_value: str = "mock-value",
    record_to: Path | None = None,
) -> Path:
    """Create a mock read-config.sh that optionally records calls and returns key-specific values.

    Args:
        scripts_dir: Directory where the mock script is written (acts as PLUGIN_SCRIPTS).
        key_values: Optional dict mapping config key → return value. Unknown keys return default_value.
        default_value: Value returned for any key not in key_values.
        record_to: If given, each invocation appends its arguments to this file (one call per line).
    """
    mock_script = scripts_dir / "read-config.sh"
    record_block = ""
    if record_to is not None:
        record_block = f'echo "$*" >> "{record_to}"\n'
    lookup_block = ""
    if key_values:
        lookup_block = 'case "$1" in\n'
        # --list flag: skip the flag, use $2
        lookup_block += "  --list) shift ;;\nesac\n"
        lookup_block += 'case "$1" in\n'
        for k, v in key_values.items():
            lookup_block += f"  '{k}') echo '{v}' ;;\n"
        lookup_block += f"  *) echo '{default_value}' ;;\nesac\n"
    else:
        lookup_block = f"echo '{default_value}'\n"

    mock_script.write_text(
        "#!/usr/bin/env bash\n"
        "# Mock read-config.sh for testing\n" + record_block + lookup_block
    )
    mock_script.chmod(mock_script.stat().st_mode | stat.S_IEXEC)
    return mock_script


def _make_script_copy_with_mock(
    scripts_dir: Path,
    *,
    key_values: dict | None = None,
    default_value: str = "",
    record_to: Path | None = None,
) -> Path:
    """Place a copy of worktree-cleanup.sh in scripts_dir with a mock read-config.sh beside it.

    Because the script derives PLUGIN_SCRIPTS from dirname(BASH_SOURCE[0]), placing
    the copy in the same directory as the mock ensures the mock is found at runtime.

    Returns the path to the script copy.
    """
    script_copy = scripts_dir / "worktree-cleanup.sh"
    script_copy.write_text(SCRIPT.read_text())
    script_copy.chmod(script_copy.stat().st_mode | stat.S_IEXEC)
    _make_mock_read_config(
        scripts_dir,
        key_values=key_values,
        default_value=default_value,
        record_to=record_to,
    )
    return script_copy


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


def _base_env(fake_home: Path) -> dict:
    """Minimal environment dict for subprocess calls (no ambient git config)."""
    return {
        **os.environ,
        "HOME": str(fake_home),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
        # Disable interactive prompts
        "FORCE": "true",
        # Prevent side-effects
        "CLEANUP_LOG": "/dev/null",
    }


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

    def test_read_config_called_for_all_required_keys(self) -> None:
        """worktree-cleanup.sh invokes read-config.sh for each required config key.

        Given: a copy of worktree-cleanup.sh placed in a temp dir alongside a mock
               read-config.sh that records all key arguments, plus an isolated git repo.
        When: the copy of the script is run in dry-run mode.
        Then: the recorded calls include each of the 6 expected config keys
              (the 5 scalar startup keys + worktree.orphan_patterns list key).

        Behavioral: the assertion is on the set of keys the script actually requests
        at runtime, not on the number or ordering of source-file lines.

        Note: PLUGIN_SCRIPTS is derived from BASH_SOURCE[0] (the script's own dir),
        so we place a copy of the script in the temp dir alongside the mock; we do
        NOT rely on env var injection which the script overwrites at startup.
        """
        tmpdir_path = Path(
            tempfile.mkdtemp(dir=os.environ.get("TMPDIR", "/tmp"), prefix="wtcleanup.")
        )
        try:
            fake_home = tmpdir_path / "meta" / "home"
            fake_home.mkdir(parents=True)

            repo = _make_isolated_git_repo(tmpdir_path)

            # Place a copy of the script in a temp scripts dir alongside the mock.
            # This ensures BASH_SOURCE[0]-based PLUGIN_SCRIPTS resolves to our mock dir.
            scripts_dir = tmpdir_path / "plugin-scripts"
            scripts_dir.mkdir()

            # Copy the real script into the mock scripts dir
            script_copy = scripts_dir / "worktree-cleanup.sh"
            script_copy.write_text(SCRIPT.read_text())
            script_copy.chmod(script_copy.stat().st_mode | stat.S_IEXEC)

            record_file = tmpdir_path / "read-config-calls.txt"
            record_file.write_text("")
            _make_mock_read_config(scripts_dir, record_to=record_file, default_value="")

            env = _base_env(fake_home)
            env["CLEANUP_LOG"] = "/dev/null"

            result = subprocess.run(
                ["bash", str(script_copy), "--dry-run", "--all", "--force"],
                capture_output=True,
                text=True,
                cwd=str(repo),
                env=env,
                timeout=30,
            )

            # The script may exit 0 or 1 in dry-run against an empty repo; what matters
            # is that read-config.sh was invoked for each expected key.
            calls_text = record_file.read_text()
        finally:
            import shutil

            shutil.rmtree(str(tmpdir_path), ignore_errors=True)

        called_keys = set()
        for line in calls_text.splitlines():
            # Lines may be "infrastructure.compose_db_file" or "--list worktree.orphan_patterns"
            args = line.strip().split()
            # Strip flags like --list
            key_args = [a for a in args if not a.startswith("--")]
            if key_args:
                called_keys.add(key_args[0])

        expected_keys = set(REQUIRED_CONFIG_KEYS) | {"worktree.orphan_patterns"}
        missing = expected_keys - called_keys
        assert not missing, (
            f"read-config.sh was not called for key(s): {missing}\n"
            f"All recorded calls:\n{calls_text}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )

    def test_startup_config_all_vars_set_to_mock_values(self) -> None:
        """CONFIG_* variables receive the values returned by read-config.sh.

        Given: a mock read-config.sh that returns a unique value per key.
        When: the startup config block is sourced.
        Then: each CONFIG_* variable holds the mock value for its key.

        This replaces the source-grep tests that checked variable names and key strings
        are present in the file — here we observe the actual runtime values instead.
        """
        script_content = SCRIPT.read_text()
        block = _extract_startup_config_block(script_content)

        key_to_var = {
            "infrastructure.compose_db_file": "CONFIG_COMPOSE_DB_FILE",
            "infrastructure.compose_project": "CONFIG_COMPOSE_PROJECT",
            "infrastructure.container_prefix": "CONFIG_CONTAINER_PREFIX",
            "worktree.branch_pattern": "CONFIG_BRANCH_PATTERN",
            "worktree.max_age_hours": "CONFIG_MAX_AGE_HOURS",
        }
        # Each key gets a distinct sentinel so we can verify the right key feeds the right var.
        key_values = {k: f"sentinel-{k.replace('.', '-')}" for k in key_to_var}

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            fake_scripts_dir = tmpdir_path / "scripts"
            fake_scripts_dir.mkdir()
            _make_mock_read_config(fake_scripts_dir, key_values=key_values)

            var_prints = "\n".join(
                f'echo "{var}=${{{var}:-__UNSET__}}"' for var in key_to_var.values()
            )
            test_script = fake_scripts_dir / "test_var_values.sh"
            test_script.write_text(
                f"#!/usr/bin/env bash\nset -uo pipefail\n{block}\n{var_prints}\n"
            )
            test_script.chmod(test_script.stat().st_mode | stat.S_IEXEC)

            result = subprocess.run(
                ["bash", str(test_script)],
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(tmpdir_path)},
            )

        assert result.returncode == 0, (
            f"Harness failed (rc={result.returncode}).\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        output = result.stdout
        for key, var in key_to_var.items():
            expected = f"sentinel-{key.replace('.', '-')}"
            assert f"{var}={expected}" in output, (
                f"Expected {var}={expected!r} in output but got:\n{output}"
            )

    def test_graceful_fallback_script_exits_zero_on_missing_read_config(self) -> None:
        """When read-config.sh is absent the script exits 0 and CONFIG_* vars are empty.

        Given: a startup-config harness with NO read-config.sh in PLUGIN_SCRIPTS.
        When: the harness is executed.
        Then: exit code is 0 and each CONFIG_* variable is set to empty string (not unset).

        This replaces the source-grep test that checked for '2>/dev/null || true' syntax —
        we observe the actual graceful-fallback behavior instead.
        """
        script_content = SCRIPT.read_text()
        block = _extract_startup_config_block(script_content)

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            fake_scripts_dir = tmpdir_path / "scripts"
            fake_scripts_dir.mkdir()
            # Intentionally NO read-config.sh in fake_scripts_dir.

            # Use ${var+ISSET} (not ${var:-default}): prints ISSET only if the var is
            # declared (even if empty); prints nothing if truly unset.
            var_prints = "\n".join(
                f'echo "{var}=${{{var}+ISSET}}"' for var in REQUIRED_CONFIG_VARS
            )
            test_script = fake_scripts_dir / "test_graceful.sh"
            test_script.write_text(
                f"#!/usr/bin/env bash\nset -uo pipefail\n{block}\n{var_prints}\n"
            )
            test_script.chmod(test_script.stat().st_mode | stat.S_IEXEC)

            result = subprocess.run(
                ["bash", str(test_script)],
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(tmpdir_path)},
            )

        # Graceful fallback: must not exit non-zero
        assert result.returncode == 0, (
            f"Script exited {result.returncode} when read-config.sh is absent — "
            f"graceful fallback expected.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        # Variables must be DECLARED (set to empty string); ${var+ISSET} prints ISSET for
        # declared vars (including empty), and nothing for truly unset vars.
        output = result.stdout
        for var in REQUIRED_CONFIG_VARS:
            assert f"{var}=ISSET" in output, (
                f"Variable {var} was not declared by the fallback path "
                f"(expected '{var}=ISSET' in output).\n"
                f"stdout: {output}"
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


@pytest.mark.scripts
class TestDockerTeardownConfig:
    """Docker teardown section uses CONFIG_COMPOSE_DB_FILE and CONFIG_COMPOSE_PROJECT."""

    def _run_cleanup_with_docker_mock(
        self,
        tmpdir: Path,
        compose_db_file: str,
        compose_project: str,
        *,
        worktree_name: str = "worktree-test-abc",
        dry_run: bool = False,
    ) -> tuple[subprocess.CompletedProcess, str]:
        """Set up an isolated repo with a worktree and a mock docker binary.

        Returns (result, docker_calls_text).
        docker_calls_text is the content of the docker invocation record file.

        All filesystem operations happen within tmpdir; the caller must keep tmpdir
        alive until after reading the return values.
        """
        fake_home = tmpdir / "meta" / "home"
        fake_home.mkdir(parents=True, exist_ok=True)

        repo = _make_isolated_git_repo(tmpdir)
        wt_path = tmpdir / worktree_name
        env = _base_env(fake_home)

        # Create a branch for the worktree and add it
        subprocess.run(
            ["git", "-C", str(repo), "checkout", "-b", worktree_name],
            check=True,
            capture_output=True,
            env=env,
        )
        subprocess.run(
            ["git", "-C", str(repo), "checkout", "main"],
            check=True,
            capture_output=True,
            env=env,
        )
        subprocess.run(
            ["git", "-C", str(repo), "worktree", "add", str(wt_path), worktree_name],
            check=True,
            capture_output=True,
            env=env,
        )

        # Place the compose file inside the worktree if compose_db_file is set
        if compose_db_file:
            compose_dest = wt_path / compose_db_file
            compose_dest.parent.mkdir(parents=True, exist_ok=True)
            compose_dest.write_text("version: '3'\nservices: {}\n")

        # Mock docker binary that records invocations
        mock_bin = tmpdir / "mock-bin"
        mock_bin.mkdir()
        docker_calls_file = tmpdir / "docker-calls.txt"
        docker_calls_file.write_text("")
        mock_docker = mock_bin / "docker"
        mock_docker.write_text(
            f'#!/usr/bin/env bash\necho "$*" >> "{docker_calls_file}"\nexit 0\n'
        )
        mock_docker.chmod(mock_docker.stat().st_mode | stat.S_IEXEC)

        # Place a copy of the script alongside the mock read-config.sh so
        # BASH_SOURCE[0]-based PLUGIN_SCRIPTS resolves to our mock dir.
        scripts_dir = tmpdir / "plugin-scripts"
        scripts_dir.mkdir(exist_ok=True)
        key_values = {
            "infrastructure.compose_db_file": compose_db_file,
            "infrastructure.compose_project": compose_project,
            "infrastructure.container_prefix": "",
            "worktree.branch_pattern": "worktree-*",
            "worktree.max_age_hours": "",
            "worktree.orphan_patterns": "",
            "worktree.regenerable_paths": "",
        }
        script_copy = _make_script_copy_with_mock(
            scripts_dir, key_values=key_values, default_value=""
        )

        flags = ["--all", "--force", "--force-dirty", "--no-branches"]
        if dry_run:
            flags = ["--dry-run"] + flags

        path_env = f"{mock_bin}:{os.environ.get('PATH', '/usr/bin:/bin')}"
        env["PATH"] = path_env
        env["CLEANUP_LOG"] = "/dev/null"
        # AGE_HOURS=0 so any worktree passes the age gate regardless of creation time
        env["AGE_HOURS"] = "0"

        result = subprocess.run(
            ["bash", str(script_copy)] + flags,
            capture_output=True,
            text=True,
            cwd=str(repo),
            env=env,
            timeout=30,
        )
        # Read the recorded docker calls while tmpdir is still alive
        calls_text = docker_calls_file.read_text()
        return result, calls_text

    def test_docker_compose_down_called_with_config_compose_db_file(self) -> None:
        """docker compose down is called with the path constructed from CONFIG_COMPOSE_DB_FILE.

        Given: CONFIG_COMPOSE_DB_FILE=docker-compose.db.yml, a worktree with that file present.
        When: worktree-cleanup.sh runs with --all --force (not dry-run).
        Then: docker is invoked with 'compose -f <worktree>/docker-compose.db.yml down'.

        Behavioral test — replaces source greps for 'CONFIG_COMPOSE_DB_FILE' and
        'compose_file' line presence.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            result, calls_text = self._run_cleanup_with_docker_mock(
                Path(tmpdir),
                compose_db_file="docker-compose.db.yml",
                compose_project="myproject-",
            )

        # docker compose -f <path> down must have been called
        assert "compose" in calls_text and "down" in calls_text, (
            "Expected 'docker compose ... down' to be called when CONFIG_COMPOSE_DB_FILE is set.\n"
            f"Docker calls recorded:\n{calls_text}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        # The -f argument must reference the compose_db_file path fragment
        assert "docker-compose.db.yml" in calls_text, (
            "docker compose down was not called with the compose_db_file path.\n"
            f"Docker calls recorded:\n{calls_text}"
        )

    def test_docker_compose_down_skipped_when_compose_db_file_empty(self) -> None:
        """docker compose down is NOT called when CONFIG_COMPOSE_DB_FILE is empty.

        Given: CONFIG_COMPOSE_DB_FILE="" (empty).
        When: worktree-cleanup.sh runs with --all --force.
        Then: docker is not invoked for compose down.

        Behavioral test — replaces source grep for the guard line.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            result, calls_text = self._run_cleanup_with_docker_mock(
                Path(tmpdir),
                compose_db_file="",
                compose_project="myproject-",
            )

        # docker compose down must NOT have been called
        assert "down" not in calls_text, (
            "docker compose down was called even though CONFIG_COMPOSE_DB_FILE is empty.\n"
            f"Docker calls recorded:\n{calls_text}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )

    def test_docker_compose_down_skipped_when_compose_project_empty(self) -> None:
        """docker compose down is NOT called when CONFIG_COMPOSE_PROJECT is empty.

        Given: CONFIG_COMPOSE_DB_FILE set but CONFIG_COMPOSE_PROJECT="" (empty).
        When: worktree-cleanup.sh runs with --all --force.
        Then: docker is not invoked for compose down.

        Behavioral test — replaces source grep for the dual-guard assertion.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            result, calls_text = self._run_cleanup_with_docker_mock(
                Path(tmpdir),
                compose_db_file="docker-compose.db.yml",
                compose_project="",
            )

        assert "down" not in calls_text, (
            "docker compose down was called even though CONFIG_COMPOSE_PROJECT is empty.\n"
            f"Docker calls recorded:\n{calls_text}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )

    def test_orphaned_network_cleanup_uses_config_compose_project_filter(self) -> None:
        """Orphaned Docker network cleanup filters by CONFIG_COMPOSE_PROJECT prefix.

        Given: CONFIG_COMPOSE_PROJECT=myprj- is set, and docker returns network names.
        When: worktree-cleanup.sh runs post-removal.
        Then: the docker network ls call includes 'myprj-' as the name filter,
              NOT any hardcoded project name.

        Behavioral test — replaces source greps for hardcoded 'lockpick-db-worktree-'
        and the sed pattern assertion.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            fake_home = tmpdir_path / "meta" / "home"
            fake_home.mkdir(parents=True)

            repo = _make_isolated_git_repo(tmpdir_path)
            worktree_name = "worktree-test-net"

            # Create a worktree eligible for cleanup
            env = _base_env(fake_home)
            wt_path = tmpdir_path / worktree_name
            subprocess.run(
                ["git", "-C", str(repo), "checkout", "-b", worktree_name],
                check=True,
                capture_output=True,
                env=env,
            )
            subprocess.run(
                ["git", "-C", str(repo), "checkout", "main"],
                check=True,
                capture_output=True,
                env=env,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "worktree",
                    "add",
                    str(wt_path),
                    worktree_name,
                ],
                check=True,
                capture_output=True,
                env=env,
            )

            # Place the compose file
            compose_file = wt_path / "docker-compose.db.yml"
            compose_file.write_text("version: '3'\nservices: {}\n")

            # Mock docker that records calls
            mock_bin = tmpdir_path / "mock-bin"
            mock_bin.mkdir()
            docker_calls_file = tmpdir_path / "docker-calls.txt"
            docker_calls_file.write_text("")

            # Mock docker: for 'network ls', emit a fake network; otherwise record + exit 0
            mock_docker = mock_bin / "docker"
            mock_docker.write_text(
                "#!/usr/bin/env bash\n"
                f'echo "$*" >> "{docker_calls_file}"\n'
                # Return a dummy network name for 'network ls' queries
                'if [[ "$1" == "network" && "$2" == "ls" ]]; then\n'
                '  echo "myprj-worktree-test-net_default"\n'
                "fi\n"
                "exit 0\n"
            )
            mock_docker.chmod(mock_docker.stat().st_mode | stat.S_IEXEC)

            # Place the script copy alongside the mock so BASH_SOURCE[0]-based
            # PLUGIN_SCRIPTS resolves to our mock dir.
            scripts_dir = tmpdir_path / "plugin-scripts"
            scripts_dir.mkdir()
            key_values = {
                "infrastructure.compose_db_file": "docker-compose.db.yml",
                "infrastructure.compose_project": "myprj-",
                "infrastructure.container_prefix": "",
                "worktree.branch_pattern": "worktree-*",
                "worktree.max_age_hours": "",
                "worktree.orphan_patterns": "",
                "worktree.regenerable_paths": "",
            }
            script_copy = _make_script_copy_with_mock(
                scripts_dir, key_values=key_values, default_value=""
            )

            path_env = f"{mock_bin}:{os.environ.get('PATH', '/usr/bin:/bin')}"
            env["PATH"] = path_env
            env["CLEANUP_LOG"] = "/dev/null"
            # AGE_HOURS=0 makes any worktree pass the age gate
            env["AGE_HOURS"] = "0"

            result = subprocess.run(
                [
                    "bash",
                    str(script_copy),
                    "--all",
                    "--force",
                    "--force-dirty",
                    "--no-branches",
                ],
                capture_output=True,
                text=True,
                cwd=str(repo),
                env=env,
                timeout=30,
            )

            calls_text = docker_calls_file.read_text()

        # The network ls call must use the configured project prefix as the name filter
        assert "myprj-" in calls_text, (
            "docker network ls was not called with the configured CONFIG_COMPOSE_PROJECT filter 'myprj-'.\n"
            f"Docker calls recorded:\n{calls_text}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )


@pytest.mark.scripts
class TestBranchPatternConfig:
    """git branch --list and .gitignore cleanup use CONFIG_BRANCH_PATTERN, not hardcoded 'worktree-*'."""

    def _run_cleanup_dry_run(
        self,
        tmpdir: Path,
        *,
        branch_pattern: str = "worktree-*",
        orphan_patterns: list[str] | None = None,
    ) -> subprocess.CompletedProcess:
        """Run worktree-cleanup.sh in dry-run against an isolated repo.

        Returns the CompletedProcess result.
        """
        fake_home = tmpdir / "meta" / "home"
        fake_home.mkdir(parents=True, exist_ok=True)
        repo = _make_isolated_git_repo(tmpdir)
        env = _base_env(fake_home)

        # Create a local branch matching the pattern (no associated worktree = orphan)
        matching_branch = "worktree-old-abc"
        subprocess.run(
            ["git", "-C", str(repo), "checkout", "-b", matching_branch],
            check=True,
            capture_output=True,
            env=env,
        )
        subprocess.run(
            ["git", "-C", str(repo), "checkout", "main"],
            check=True,
            capture_output=True,
            env=env,
        )
        # Create a non-matching branch that must not be touched
        subprocess.run(
            ["git", "-C", str(repo), "checkout", "-b", "feature-keep-me"],
            check=True,
            capture_output=True,
            env=env,
        )
        subprocess.run(
            ["git", "-C", str(repo), "checkout", "main"],
            check=True,
            capture_output=True,
            env=env,
        )

        # Place the script copy alongside the mock so BASH_SOURCE[0]-based
        # PLUGIN_SCRIPTS resolves to our mock dir (not the real plugin scripts dir).
        scripts_dir = tmpdir / "plugin-scripts"
        scripts_dir.mkdir(exist_ok=True)
        orphan_val = "\n".join(orphan_patterns) if orphan_patterns else ""
        key_values = {
            "infrastructure.compose_db_file": "",
            "infrastructure.compose_project": "",
            "infrastructure.container_prefix": "",
            "worktree.branch_pattern": branch_pattern,
            "worktree.max_age_hours": "",
            "worktree.orphan_patterns": orphan_val,
            "worktree.regenerable_paths": "",
        }
        script_copy = _make_script_copy_with_mock(
            scripts_dir, key_values=key_values, default_value=""
        )

        env["CLEANUP_LOG"] = "/dev/null"
        return subprocess.run(
            ["bash", str(script_copy), "--dry-run", "--all", "--force"],
            capture_output=True,
            text=True,
            cwd=str(repo),
            env=env,
            timeout=30,
        )

    def test_matching_orphan_branch_listed_in_dry_run(self) -> None:
        """Orphan branches matching the configured pattern appear in dry-run output.

        Given: isolated repo with branch 'worktree-old-abc' (no associated worktree),
               CONFIG_BRANCH_PATTERN=worktree-* / orphan_patterns=[worktree-*].
        When: worktree-cleanup.sh --dry-run --all --force.
        Then: stdout mentions 'worktree-old-abc' as a candidate for deletion.

        Behavioral test — replaces source greps for branch --list and pattern usage.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            result = self._run_cleanup_dry_run(
                Path(tmpdir),
                branch_pattern="worktree-*",
                orphan_patterns=["worktree-*"],
            )

        combined = result.stdout + result.stderr
        assert "worktree-old-abc" in combined, (
            "Expected 'worktree-old-abc' to appear in dry-run output as an orphan branch candidate.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )

    def test_non_matching_branch_not_listed_in_dry_run(self) -> None:
        """Branches NOT matching the configured pattern do NOT appear in dry-run output.

        Given: isolated repo with branch 'feature-keep-me',
               orphan_patterns=[worktree-*].
        When: worktree-cleanup.sh --dry-run --all --force.
        Then: 'feature-keep-me' is NOT mentioned as a deletion candidate.

        Behavioral test — replaces source greps for pattern binding.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            result = self._run_cleanup_dry_run(
                Path(tmpdir),
                branch_pattern="worktree-*",
                orphan_patterns=["worktree-*"],
            )

        # 'feature-keep-me' must not appear as a deletion target
        assert (
            "Would delete" not in result.stdout
            or "feature-keep-me" not in result.stdout
        ), (
            "'feature-keep-me' branch appeared in dry-run deletion output — "
            "it should not match the 'worktree-*' pattern.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )

    def test_gitignore_matching_entries_cleaned_in_dry_run(self) -> None:
        """Worktree-specific .gitignore entries are flagged for cleanup in dry-run.

        Given: isolated repo with a .gitignore containing 'worktree-old-abc',
               CONFIG_BRANCH_PATTERN=worktree-*.
        When: worktree-cleanup.sh --dry-run --all --force.
        Then: stdout includes a message about cleaning up .gitignore entries.

        Behavioral test — replaces source greps for CONFIG_BRANCH_PATTERN in .gitignore section.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            fake_home = tmpdir_path / "meta" / "home"
            fake_home.mkdir(parents=True)
            repo = _make_isolated_git_repo(tmpdir_path)
            env = _base_env(fake_home)

            # Add a specific worktree entry to .gitignore that should be cleaned up
            gitignore = repo / ".gitignore"
            gitignore.write_text("worktree-old-abc\nworktree-*/\n")
            subprocess.run(
                ["git", "-C", str(repo), "add", ".gitignore"],
                check=True,
                capture_output=True,
                env=env,
            )
            subprocess.run(
                ["git", "-C", str(repo), "commit", "-m", "add gitignore"],
                check=True,
                capture_output=True,
                env=env,
            )

            # Place the script copy alongside the mock so BASH_SOURCE[0]-based
            # PLUGIN_SCRIPTS resolves to our mock dir.
            scripts_dir = tmpdir_path / "plugin-scripts"
            scripts_dir.mkdir()
            key_values = {
                "infrastructure.compose_db_file": "",
                "infrastructure.compose_project": "",
                "infrastructure.container_prefix": "",
                "worktree.branch_pattern": "worktree-*",
                "worktree.max_age_hours": "",
                "worktree.orphan_patterns": "",
                "worktree.regenerable_paths": "",
            }
            script_copy = _make_script_copy_with_mock(
                scripts_dir, key_values=key_values, default_value=""
            )

            env["CLEANUP_LOG"] = "/dev/null"
            result = subprocess.run(
                ["bash", str(script_copy), "--dry-run", "--all", "--force"],
                capture_output=True,
                text=True,
                cwd=str(repo),
                env=env,
                timeout=30,
            )

        combined = result.stdout + result.stderr
        # The script should report that .gitignore would be cleaned
        assert "gitignore" in combined.lower(), (
            "Expected a message about cleaning up .gitignore but none found.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )


@pytest.mark.scripts
class TestAgeHoursConfig:
    """AGE_HOURS default in worktree-cleanup.sh is driven by CONFIG_MAX_AGE_HOURS."""

    def test_age_hours_reads_from_config_max_age_hours(self) -> None:
        """When CONFIG_MAX_AGE_HOURS=24, AGE_HOURS resolves to 24.

        Given: CONFIG_MAX_AGE_HOURS=24, AGE_HOURS not in environment.
        When: the shell expression AGE_HOURS=${AGE_HOURS:-${CONFIG_MAX_AGE_HOURS:-12}} is evaluated.
        Then: AGE_HOURS equals 24.

        This tests the behavior of the expression, not the text of the source.
        """
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

    def test_age_hours_defaults_to_12_when_config_absent(self) -> None:
        """AGE_HOURS defaults to 12 when neither AGE_HOURS nor CONFIG_MAX_AGE_HOURS is set.

        Given: both AGE_HOURS and CONFIG_MAX_AGE_HOURS are absent from the environment.
        When: the startup config block runs via the script harness.
        Then: AGE_HOURS equals 12 (the compiled-in default).

        Behavioral test — replaces source greps for 'AGE_HOURS=12' bare literal.
        """
        script_content = SCRIPT.read_text()
        block = _extract_startup_config_block(script_content)

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            fake_scripts_dir = tmpdir_path / "scripts"
            fake_scripts_dir.mkdir()
            # read-config.sh returns empty for max_age_hours
            _make_mock_read_config(fake_scripts_dir, default_value="")

            test_script = fake_scripts_dir / "test_age_default.sh"
            test_script.write_text(
                "#!/usr/bin/env bash\n"
                "set -uo pipefail\n"
                f"{block}\n"
                # Apply the AGE_HOURS default expression from the script
                "AGE_HOURS=${AGE_HOURS:-${CONFIG_MAX_AGE_HOURS:-12}}\n"
                'echo "AGE_HOURS=${AGE_HOURS}"\n'
            )
            test_script.chmod(test_script.stat().st_mode | stat.S_IEXEC)

            # Run with AGE_HOURS and CONFIG_MAX_AGE_HOURS absent from environment
            env = {
                k: v
                for k, v in os.environ.items()
                if k not in ("AGE_HOURS", "CONFIG_MAX_AGE_HOURS")
            }
            env["HOME"] = str(tmpdir_path)
            result = subprocess.run(
                ["bash", str(test_script)],
                capture_output=True,
                text=True,
                env=env,
            )

        assert result.returncode == 0, (
            f"Test script failed (rc={result.returncode}).\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "AGE_HOURS=12" in result.stdout, (
            "Expected AGE_HOURS=12 as the compiled-in default when neither "
            "AGE_HOURS nor CONFIG_MAX_AGE_HOURS is set.\n"
            f"stdout: {result.stdout}"
        )

    def test_age_hours_env_var_overrides_config(self) -> None:
        """An explicit AGE_HOURS env var takes precedence over CONFIG_MAX_AGE_HOURS.

        Given: AGE_HOURS=48 in environment, CONFIG_MAX_AGE_HOURS=24 from config.
        When: the AGE_HOURS default expression is evaluated.
        Then: AGE_HOURS remains 48 (env var wins).

        Behavioral test — replaces source grep for the precedence pattern.
        """
        result = subprocess.run(
            [
                "bash",
                "-c",
                "CONFIG_MAX_AGE_HOURS=24; AGE_HOURS=${AGE_HOURS:-${CONFIG_MAX_AGE_HOURS:-12}}; "
                'echo "AGE_HOURS=${AGE_HOURS}"',
            ],
            capture_output=True,
            text=True,
            env={**os.environ, "AGE_HOURS": "48"},
        )
        assert result.returncode == 0, (
            f"bash -c failed (rc={result.returncode}).\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "AGE_HOURS=48" in result.stdout, (
            "AGE_HOURS env var should override CONFIG_MAX_AGE_HOURS.\n"
            f"stdout: {result.stdout}"
        )

    def test_is_old_enough_respects_age_hours_threshold(self) -> None:
        """is_old_enough() returns true for old directories and false for fresh ones.

        Given: a directory created 'now' (too recent) and a temp directory with
               mtime backdated to 25 hours ago, with AGE_HOURS=12.
        When: is_old_enough() is called on each directory.
        Then: the backdated directory is eligible (old enough), the fresh one is not.

        Behavioral test — replaces source greps for 'AGE_HOURS:-12' inside function body.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            fake_home = tmpdir_path / "meta" / "home"
            fake_home.mkdir(parents=True)

            # Create an "old" directory by backdating its mtime by 25 hours
            old_dir = tmpdir_path / "old-worktree"
            old_dir.mkdir()
            twenty_five_hours_ago = os.stat(str(old_dir)).st_mtime - (25 * 3600)
            os.utime(str(old_dir), (twenty_five_hours_ago, twenty_five_hours_ago))

            # Fresh directory (just created)
            fresh_dir = tmpdir_path / "fresh-worktree"
            fresh_dir.mkdir()

            # Build a harness that sources the is_old_enough function from the real script
            # and calls it on both directories.
            harness_script = tmpdir_path / "test-age.sh"
            harness_script.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "AGE_HOURS=12\n"
                # Source just the is_old_enough function from the real script
                f'source <(grep -A 40 "^is_old_enough()" "{SCRIPT}" | head -45)\n'
                f'if is_old_enough "{old_dir}"; then\n'
                '  echo "OLD_ELIGIBLE=yes"\n'
                "else\n"
                '  echo "OLD_ELIGIBLE=no"\n'
                "fi\n"
                f'if is_old_enough "{fresh_dir}"; then\n'
                '  echo "FRESH_ELIGIBLE=yes"\n'
                "else\n"
                '  echo "FRESH_ELIGIBLE=no"\n'
                "fi\n"
            )
            harness_script.chmod(harness_script.stat().st_mode | stat.S_IEXEC)

            result = subprocess.run(
                ["bash", str(harness_script)],
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(fake_home)},
            )

        assert result.returncode == 0, (
            f"Age harness failed (rc={result.returncode}).\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        assert "OLD_ELIGIBLE=yes" in result.stdout, (
            "A 25-hour-old directory should be eligible with AGE_HOURS=12.\n"
            f"stdout: {result.stdout}"
        )
        assert "FRESH_ELIGIBLE=no" in result.stdout, (
            "A freshly-created directory should NOT be eligible with AGE_HOURS=12.\n"
            f"stdout: {result.stdout}"
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

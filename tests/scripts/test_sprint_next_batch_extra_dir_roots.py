"""RED test for bug cb22-7c24: extract_files() dir_roots should be config-driven.

When SPRINT_CFG_EXTRA_DIR_ROOTS=lib,config is set, extract_files() must match
prose paths rooted at "lib/" (e.g. "lib/models/user.py").

Currently FAILS because "lib" is hardcoded-absent from dir_roots (line 382 of
sprint-next-batch.sh only contains {cfg_src_dir, cfg_test_dir, "app", ".claude",
"plugins"}).  Will PASS after the fix adds the extra roots from
SPRINT_CFG_EXTRA_DIR_ROOTS into dir_roots.
"""

import json
import os
import subprocess


REPO_ROOT = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
SCRIPT = os.path.join(REPO_ROOT, "plugins/dso/scripts/sprint-next-batch.sh")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _extract_function_source(script_path: str, fn_name: str) -> str:
    """Extract a top-level Python function definition from the PYEOF block of a
    bash script.  Returns the source lines from 'def <fn_name>(' up to (but not
    including) the next top-level definition or the end of the PYEOF block.
    """
    # Collect lines inside the PYEOF heredoc
    pyeof_lines: list[str] = []
    inside = False
    with open(script_path) as fh:
        for line in fh:
            stripped = line.rstrip()
            if not inside:
                if stripped == "python3 - <<'PYEOF'":
                    inside = True
                continue
            if stripped == "PYEOF":
                break
            pyeof_lines.append(line)

    assert pyeof_lines, f"Could not locate PYEOF block in {script_path}"

    # Find the start of the target function
    start_idx: int | None = None
    for i, line in enumerate(pyeof_lines):
        if line.startswith(f"def {fn_name}("):
            start_idx = i
            break

    assert start_idx is not None, f"Could not find 'def {fn_name}' in PYEOF block"

    # Collect lines until the next top-level definition (non-indented 'def' or 'class')
    fn_lines = [pyeof_lines[start_idx]]
    for line in pyeof_lines[start_idx + 1 :]:
        # A new top-level def/class or a non-empty, non-indented non-comment line
        # signals the end of this function.
        if line and line[0] not in (" ", "\t", "\n", "#") and line.strip():
            break
        fn_lines.append(line)

    return "".join(fn_lines)


def _run_extract_files(text: str, extra_dir_roots: str = "") -> set[str]:
    """Run extract_files() from sprint-next-batch.sh's embedded Python block.

    Builds a minimal Python driver that:
      1. Imports only stdlib modules needed by extract_files
      2. Seeds the module-level variables the function reads (cfg_src_dir, etc.)
      3. Defines extract_files() by exec-ing its extracted source
      4. Calls extract_files(text) and prints the JSON result to stdout

    The text argument is passed via stdin.
    Returns the set of file paths returned by extract_files(text).
    """
    fn_source = _extract_function_source(SCRIPT, "extract_files")

    driver = (
        "import json\n"
        "import os\n"
        "import re\n"
        "import sys\n"
        "\n"
        "# Module-level variables that extract_files() closes over\n"
        "cfg_src_dir       = os.environ.get('SPRINT_CFG_SRC_DIR', 'src')\n"
        "cfg_test_dir      = os.environ.get('SPRINT_CFG_TEST_DIR', 'tests')\n"
        "cfg_test_unit_dir = os.environ.get('SPRINT_CFG_TEST_UNIT_DIR', 'tests/unit')\n"
        "cfg_extra_dir_roots = os.environ.get('SPRINT_CFG_EXTRA_DIR_ROOTS', '')\n"
        "\n" + fn_source + "\n"
        "text = sys.stdin.read()\n"
        "result = extract_files(text)\n"
        "print(json.dumps(sorted(result)))\n"
    )

    env = os.environ.copy()
    env["SPRINT_CFG_SRC_DIR"] = "src"
    env["SPRINT_CFG_TEST_DIR"] = "tests"
    env["SPRINT_CFG_TEST_UNIT_DIR"] = "tests/unit"
    if extra_dir_roots:
        env["SPRINT_CFG_EXTRA_DIR_ROOTS"] = extra_dir_roots
    else:
        env.pop("SPRINT_CFG_EXTRA_DIR_ROOTS", None)

    result = subprocess.run(
        ["python3", "-c", driver],
        input=text,
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode == 0, (
        f"Driver script failed (exit {result.returncode}).\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}\n\n"
        f"--- driver source ---\n{driver}\n--- end driver ---"
    )
    return set(json.loads(result.stdout))


# ---------------------------------------------------------------------------
# RED test
# ---------------------------------------------------------------------------


class TestExtractFilesExtraDirRoots:
    """extract_files() must honour SPRINT_CFG_EXTRA_DIR_ROOTS."""

    def test_extra_dir_root_lib_matches_lib_path(self) -> None:
        """When SPRINT_CFG_EXTRA_DIR_ROOTS=lib,config, a prose mention of
        lib/models/user.py must appear in extract_files() output.

        RED: fails before implementation because "lib" is not in the hardcoded
             dir_roots set (sprint-next-batch.sh line 382).
        GREEN: passes after SPRINT_CFG_EXTRA_DIR_ROOTS is read and appended to
               dir_roots inside extract_files().
        """
        text = (
            "Update lib/models/user.py to add the new field and "
            "adjust config/settings.py accordingly."
        )
        extracted = _run_extract_files(text, extra_dir_roots="lib,config")

        assert "lib/models/user.py" in extracted, (
            f"Expected 'lib/models/user.py' in extract_files() output when "
            f"SPRINT_CFG_EXTRA_DIR_ROOTS=lib,config, but got: {sorted(extracted)!r}"
        )

    def test_extra_dir_root_lib_not_matched_without_env(self) -> None:
        """Without SPRINT_CFG_EXTRA_DIR_ROOTS, lib/models/user.py must NOT be
        extracted from prose (only backtick-delimited paths bypass dir_roots).

        This confirms the before-fix baseline so the RED test above is measuring
        the correct thing — it must fail for the right reason.
        """
        text = "Update lib/models/user.py to add the new field."
        extracted = _run_extract_files(text, extra_dir_roots="")

        assert "lib/models/user.py" not in extracted, (
            f"lib/models/user.py should NOT be extracted from prose without "
            f"SPRINT_CFG_EXTRA_DIR_ROOTS set, but got: {sorted(extracted)!r}"
        )

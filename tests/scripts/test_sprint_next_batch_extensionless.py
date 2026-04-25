"""RED test for bug 3a6d-30b7: extension-less files invisible to overlap detector.

When a task description references plugins/dso/scripts/ticket (no file extension),
extract_files() must include it in its output so the SKIPPED_OVERLAP signal fires
when two tasks share that file.

Currently FAILS because both regexes in extract_files() require a file extension:
  - backtick regex: r"`([^`]+[.]\\w+)`"  (requires extension at end)
  - prose regex: r"\\b((?:<dirs>)/[\\w/\\-.]+[.](?:py|sh|md|...))\\b"  (requires extension)

Will PASS after KNOWN_EXTENSIONLESS_FILES is added to extract_files() so that
the path 'plugins/dso/scripts/ticket' is matched by name even without an extension.
"""

import json
import os
import subprocess

REPO_ROOT = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
SCRIPT = os.path.join(REPO_ROOT, "plugins/dso/scripts/ticket-next-batch.sh")


def _extract_function_source(script_path: str, fn_name: str) -> str:
    """Extract a top-level Python function definition from the PYEOF block."""
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

    start_idx: int | None = None
    for i, line in enumerate(pyeof_lines):
        if line.startswith(f"def {fn_name}("):
            start_idx = i
            break

    assert start_idx is not None, f"Could not find 'def {fn_name}' in PYEOF block"

    fn_lines = [pyeof_lines[start_idx]]
    for line in pyeof_lines[start_idx + 1 :]:
        if line and line[0] not in (" ", "\t", "\n", "#") and line.strip():
            break
        fn_lines.append(line)

    return "".join(fn_lines)


def _run_extract_files(text: str) -> set[str]:
    """Run extract_files() from sprint-next-batch.sh's embedded Python block."""
    fn_source = _extract_function_source(SCRIPT, "extract_files")

    driver = (
        "import json\n"
        "import os\n"
        "import re\n"
        "import sys\n"
        "\n"
        "cfg_src_dir       = os.environ.get('SPRINT_CFG_SRC_DIR', 'src')\n"
        "cfg_test_dir      = os.environ.get('SPRINT_CFG_TEST_DIR', 'tests')\n"
        "cfg_test_unit_dir = os.environ.get('SPRINT_CFG_TEST_UNIT_DIR', 'tests/unit')\n"
        "cfg_extra_dir_roots = os.environ.get('SPRINT_CFG_EXTRA_DIR_ROOTS', '')\n"
        "cfg_known_extensionless = os.environ.get('SPRINT_KNOWN_EXTENSIONLESS_FILES', '')\n"
        "\n" + fn_source + "\n"
        "text = sys.stdin.read()\n"
        "result = extract_files(text)\n"
        "print(json.dumps(sorted(result)))\n"
    )

    env = os.environ.copy()
    env["SPRINT_CFG_SRC_DIR"] = "src"
    env["SPRINT_CFG_TEST_DIR"] = "tests"
    env["SPRINT_CFG_TEST_UNIT_DIR"] = "tests/unit"
    env.pop("SPRINT_CFG_EXTRA_DIR_ROOTS", None)
    env["SPRINT_KNOWN_EXTENSIONLESS_FILES"] = "plugins/dso/scripts/ticket"

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


class TestExtractFilesExtensionless:
    """extract_files() must detect known extension-less dispatcher files."""

    def test_ticket_dispatcher_detected_in_backtick(self) -> None:
        """When a task description backtick-quotes `plugins/dso/scripts/ticket`,
        extract_files() must include it — even though it has no file extension.

        RED: fails before fix because the backtick regex requires a file extension at the end.
        GREEN: passes after KNOWN_EXTENSIONLESS_FILES is added.
        """
        text = "Modify `plugins/dso/scripts/ticket` to add a new subcommand."
        result = _run_extract_files(text)
        assert "plugins/dso/scripts/ticket" in result, (
            f"Expected 'plugins/dso/scripts/ticket' in extract_files output "
            f"for backtick reference, but got: {sorted(result)}"
        )

    def test_ticket_dispatcher_detected_in_prose(self) -> None:
        """When a task description mentions plugins/dso/scripts/ticket in prose,
        extract_files() must include it.

        RED: fails before fix because the prose regex requires a file extension.
        GREEN: passes after KNOWN_EXTENSIONLESS_FILES is added.
        """
        text = "Update plugins/dso/scripts/ticket to handle the new dispatch path."
        result = _run_extract_files(text)
        assert "plugins/dso/scripts/ticket" in result, (
            f"Expected 'plugins/dso/scripts/ticket' in extract_files output "
            f"for prose reference, but got: {sorted(result)}"
        )

    def test_extensioned_files_still_detected(self) -> None:
        """Regression guard: adding KNOWN_EXTENSIONLESS_FILES must not break
        detection of normal extension-bearing files.
        """
        text = "Edit `plugins/dso/scripts/ticket-lib.sh` for the new logic."
        result = _run_extract_files(text)
        assert "plugins/dso/scripts/ticket-lib.sh" in result, (
            f"Expected 'plugins/dso/scripts/ticket-lib.sh' in extract_files output, "
            f"but got: {sorted(result)}"
        )

"""RED tests for agentic UI pattern entries in ui-reference/patterns/.

These tests are RED — they assert behavior that does not yet exist.
All tests MUST FAIL before the GREEN task creates the files.

Corpus location: plugins/dso/data/ui-reference/patterns/
Schema checker:  plugins/dso/scripts/check-corpus-schema.py
Query tool:      plugins/dso/scripts/ref-query.py

Run:
    python3 -m pytest tests/scripts/test_corpus_patterns_agentic.py -v

All tests must FAIL in RED phase (before GREEN task creates the files).
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
import yaml

# ---------------------------------------------------------------------------
# Repo-relative constants
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
PATTERNS_DIR = REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "patterns"

SCHEMA_CHECKER = REPO_ROOT / "plugins" / "dso" / "scripts" / "check-corpus-schema.py"
REF_QUERY = REPO_ROOT / "plugins" / "dso" / "scripts" / "ref-query.py"

# Required fields that every agentic corpus entry must have
REQUIRED_ENTRY_FIELDS = {"id", "title", "domain", "action", "compliance", "severity"}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_yaml(path: Path) -> object:
    """Load a YAML file and return its parsed content."""
    with path.open() as fh:
        return yaml.safe_load(fh)


def _get_agentic_files() -> list[Path]:
    """Return all YAML files in patterns/ that are agentic-related.

    A file is agentic-related if 'agentic' appears in the filename.
    """
    if not PATTERNS_DIR.exists():
        return []
    return sorted(f for f in PATTERNS_DIR.glob("agentic-*.yaml"))


# ---------------------------------------------------------------------------
# Test 1: >=5 agentic YAML files exist in patterns/
# ---------------------------------------------------------------------------


def test_patterns_agentic_files_exist() -> None:
    """>=5 YAML files with 'agentic' in the filename must exist in patterns/.

    RED: No agentic-*.yaml files exist yet — this assertion FAILS before
    the GREEN task creates the files.
    """
    agentic_files = _get_agentic_files()
    assert len(agentic_files) >= 5, (
        f"Expected >=5 agentic-*.yaml files in {PATTERNS_DIR}, "
        f"found {len(agentic_files)}: {[f.name for f in agentic_files]}\n"
        "Run GREEN task (f3e7-0848) to create the agentic pattern corpus files."
    )


# ---------------------------------------------------------------------------
# Test 2: All agentic entries have required fields
# ---------------------------------------------------------------------------


def test_agentic_entries_have_required_fields() -> None:
    """Every agentic corpus YAML file must have: id, title, domain, action,
    compliance, severity.

    RED: No agentic-*.yaml files exist yet — pytest.fail fires before field
    checks can run, so this assertion FAILS before the GREEN task.
    """
    agentic_files = _get_agentic_files()
    if not agentic_files:
        pytest.fail(
            f"No agentic-*.yaml files found in {PATTERNS_DIR}; "
            "required-field assertions cannot run. "
            "Run GREEN task (f3e7-0848) to create the files."
        )

    errors: list[str] = []
    for fpath in agentic_files:
        data = _load_yaml(fpath)
        if not isinstance(data, dict):
            errors.append(f"{fpath.name}: expected a YAML mapping, got {type(data)}")
            continue
        missing = REQUIRED_ENTRY_FIELDS - set(data.keys())
        if missing:
            errors.append(f"{fpath.name}: missing required fields: {sorted(missing)}")

    assert not errors, (
        "Agentic corpus entries are missing required fields:\n"
        + "\n".join(f"  - {e}" for e in errors)
    )


# ---------------------------------------------------------------------------
# Test 3: check-corpus-schema exits 0 on all patterns/ files
# ---------------------------------------------------------------------------


def test_agentic_entries_schema_valid() -> None:
    """check-corpus-schema.py must exit 0 on all files in patterns/.

    RED: No agentic-*.yaml files exist yet — the schema validator will find
    zero files to validate OR find missing agentic files; this assertion FAILS
    before the GREEN task creates the files.
    """
    agentic_files = _get_agentic_files()
    if not agentic_files:
        pytest.fail(
            f"No agentic-*.yaml files found in {PATTERNS_DIR}; "
            "schema validation cannot run. "
            "Run GREEN task (f3e7-0848) to create the files."
        )

    schema_path = (
        REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "_schema.yaml"
    )
    result = subprocess.run(
        [
            "python3",
            str(SCHEMA_CHECKER),
            str(PATTERNS_DIR),
            "--schema",
            str(schema_path),
        ],
        capture_output=True,
        text=True,
        timeout=60,
        cwd=str(REPO_ROOT),
    )
    assert result.returncode == 0, (
        f"check-corpus-schema.py exited {result.returncode} on patterns/ directory.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )

"""RED tests for dark pattern taxonomy entries in ui-reference/patterns/.

These tests are RED — they assert behavior that does not yet exist.
All tests MUST FAIL before the GREEN task creates the patterns/ files.

Corpus location: plugins/dso/data/ui-reference/patterns/
Schema checker:  plugins/dso/scripts/check-corpus-schema.sh
Query tool:      plugins/dso/scripts/ref-query.sh (or dso ref-query subcommand)

Run:
    python3 -m pytest tests/scripts/test_corpus_patterns_dark.py -v

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

# Expected taxonomy files (from GREEN task AC)
EXPECTED_FILES = {
    "brignull-dark-patterns.yaml",
    "aidui-taxonomy.yaml",
    "cognitive-load-checklist.yaml",
}

SCHEMA_CHECKER = REPO_ROOT / "plugins" / "dso" / "scripts" / "check-corpus-schema.sh"
REF_QUERY = REPO_ROOT / "plugins" / "dso" / "scripts" / "ref-query.sh"


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------


def _load_yaml(path: Path) -> object:
    """Load a YAML file and return its parsed content."""
    with path.open() as f:
        return yaml.safe_load(f)


# ---------------------------------------------------------------------------
# Test 1: Brignull dark pattern taxonomy file exists in patterns/
# ---------------------------------------------------------------------------


def test_brignull_dark_patterns_yaml_exists() -> None:
    """Brignull dark pattern taxonomy YAML file must exist in patterns/ directory.

    RED: plugins/dso/data/ui-reference/patterns/brignull-dark-patterns.yaml
    does not exist yet — this assertion FAILS before the GREEN task runs.
    """
    target = PATTERNS_DIR / "brignull-dark-patterns.yaml"
    assert target.exists(), (
        f"Brignull dark patterns file not found at {target}. "
        "Expected plugins/dso/data/ui-reference/patterns/brignull-dark-patterns.yaml"
    )


# ---------------------------------------------------------------------------
# Test 2: AidUI taxonomy file exists in patterns/
# ---------------------------------------------------------------------------


def test_aidui_taxonomy_yaml_exists() -> None:
    """AidUI 27-class taxonomy YAML file must exist in patterns/ directory.

    RED: plugins/dso/data/ui-reference/patterns/aidui-taxonomy.yaml
    does not exist yet — this assertion FAILS before the GREEN task runs.
    """
    target = PATTERNS_DIR / "aidui-taxonomy.yaml"
    assert target.exists(), (
        f"AidUI taxonomy file not found at {target}. "
        "Expected plugins/dso/data/ui-reference/patterns/aidui-taxonomy.yaml"
    )


# ---------------------------------------------------------------------------
# Test 3: Cognitive load checklist file exists in patterns/
# ---------------------------------------------------------------------------


def test_cognitive_load_checklist_yaml_exists() -> None:
    """Cognitive load checklist YAML file must exist in patterns/ directory.

    RED: plugins/dso/data/ui-reference/patterns/cognitive-load-checklist.yaml
    does not exist yet — this assertion FAILS before the GREEN task runs.
    """
    target = PATTERNS_DIR / "cognitive-load-checklist.yaml"
    assert target.exists(), (
        f"Cognitive load checklist file not found at {target}. "
        "Expected plugins/dso/data/ui-reference/patterns/cognitive-load-checklist.yaml"
    )


# ---------------------------------------------------------------------------
# Test 4: Brignull file has domain: patterns
# ---------------------------------------------------------------------------


def test_brignull_entries_have_domain_patterns() -> None:
    """All entries in brignull-dark-patterns.yaml must have domain: patterns (or [patterns]).

    RED: File does not exist yet, so loading it fails — assertion FAILS before
    the GREEN task creates the file.
    """
    target = PATTERNS_DIR / "brignull-dark-patterns.yaml"
    if not target.exists():
        pytest.fail(
            f"brignull-dark-patterns.yaml not found at {target}; "
            "domain: patterns cannot be verified"
        )

    data = _load_yaml(target)
    assert data is not None, "brignull-dark-patterns.yaml parsed as empty/null"

    # The file may be a list of entries or a dict with an 'entries' key
    if isinstance(data, list):
        entries = data
    elif isinstance(data, dict):
        entries = data.get("entries", [data])
    else:
        pytest.fail(
            f"Unexpected YAML structure in brignull-dark-patterns.yaml: {type(data)}"
        )

    assert len(entries) >= 1, (
        "brignull-dark-patterns.yaml must contain at least one entry"
    )

    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            continue
        domain = entry.get("domain")
        # domain may be a string "patterns" or a list ["patterns"]
        if isinstance(domain, list):
            assert "patterns" in domain, (
                f"Entry {i} in brignull-dark-patterns.yaml has domain={domain!r}; "
                "expected 'patterns' to be present"
            )
        else:
            assert domain == "patterns", (
                f"Entry {i} in brignull-dark-patterns.yaml has domain={domain!r}; "
                "expected 'patterns'"
            )


# ---------------------------------------------------------------------------
# Test 5: AidUI file has domain: patterns
# ---------------------------------------------------------------------------


def test_aidui_entries_have_domain_patterns() -> None:
    """All entries in aidui-taxonomy.yaml must have domain: patterns (or [patterns]).

    RED: File does not exist yet — assertion FAILS before the GREEN task creates it.
    """
    target = PATTERNS_DIR / "aidui-taxonomy.yaml"
    if not target.exists():
        pytest.fail(
            f"aidui-taxonomy.yaml not found at {target}; "
            "domain: patterns cannot be verified"
        )

    data = _load_yaml(target)
    assert data is not None, "aidui-taxonomy.yaml parsed as empty/null"

    if isinstance(data, list):
        entries = data
    elif isinstance(data, dict):
        entries = data.get("entries", [data])
    else:
        pytest.fail(f"Unexpected YAML structure in aidui-taxonomy.yaml: {type(data)}")

    assert len(entries) >= 1, "aidui-taxonomy.yaml must contain at least one entry"

    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            continue
        domain = entry.get("domain")
        if isinstance(domain, list):
            assert "patterns" in domain, (
                f"Entry {i} in aidui-taxonomy.yaml has domain={domain!r}; "
                "expected 'patterns' to be present"
            )
        else:
            assert domain == "patterns", (
                f"Entry {i} in aidui-taxonomy.yaml has domain={domain!r}; "
                "expected 'patterns'"
            )


# ---------------------------------------------------------------------------
# Test 6: Cognitive load file has domain: patterns
# ---------------------------------------------------------------------------


def test_cognitive_load_entries_have_domain_patterns() -> None:
    """All entries in cognitive-load-checklist.yaml must have domain: patterns.

    RED: File does not exist yet — assertion FAILS before the GREEN task creates it.
    """
    target = PATTERNS_DIR / "cognitive-load-checklist.yaml"
    if not target.exists():
        pytest.fail(
            f"cognitive-load-checklist.yaml not found at {target}; "
            "domain: patterns cannot be verified"
        )

    data = _load_yaml(target)
    assert data is not None, "cognitive-load-checklist.yaml parsed as empty/null"

    if isinstance(data, list):
        entries = data
    elif isinstance(data, dict):
        entries = data.get("entries", [data])
    else:
        pytest.fail(
            f"Unexpected YAML structure in cognitive-load-checklist.yaml: {type(data)}"
        )

    assert len(entries) >= 1, (
        "cognitive-load-checklist.yaml must contain at least one entry"
    )

    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            continue
        domain = entry.get("domain")
        if isinstance(domain, list):
            assert "patterns" in domain, (
                f"Entry {i} in cognitive-load-checklist.yaml has domain={domain!r}; "
                "expected 'patterns' to be present"
            )
        else:
            assert domain == "patterns", (
                f"Entry {i} in cognitive-load-checklist.yaml has domain={domain!r}; "
                "expected 'patterns'"
            )


# ---------------------------------------------------------------------------
# Test 7: check-corpus-schema passes on brignull-dark-patterns.yaml
# ---------------------------------------------------------------------------


def test_check_corpus_schema_passes_on_brignull() -> None:
    """check-corpus-schema.sh must exit 0 on brignull-dark-patterns.yaml.

    RED: check-corpus-schema.sh does not exist yet AND the target file does not
    exist — both conditions cause this assertion to FAIL before the GREEN task.
    """
    if not SCHEMA_CHECKER.exists():
        pytest.fail(
            f"check-corpus-schema.sh not found at {SCHEMA_CHECKER}; "
            "schema validation cannot run"
        )

    target = PATTERNS_DIR / "brignull-dark-patterns.yaml"
    if not target.exists():
        pytest.fail(
            f"brignull-dark-patterns.yaml not found at {target}; "
            "schema validation cannot run"
        )

    result = subprocess.run(
        ["bash", str(SCHEMA_CHECKER), str(target)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"check-corpus-schema.sh failed on brignull-dark-patterns.yaml "
        f"(exit {result.returncode}).\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 8: check-corpus-schema passes on aidui-taxonomy.yaml
# ---------------------------------------------------------------------------


def test_check_corpus_schema_passes_on_aidui() -> None:
    """check-corpus-schema.sh must exit 0 on aidui-taxonomy.yaml.

    RED: check-corpus-schema.sh does not exist yet — assertion FAILS before
    the GREEN task creates the script and the file.
    """
    if not SCHEMA_CHECKER.exists():
        pytest.fail(
            f"check-corpus-schema.sh not found at {SCHEMA_CHECKER}; "
            "schema validation cannot run"
        )

    target = PATTERNS_DIR / "aidui-taxonomy.yaml"
    if not target.exists():
        pytest.fail(
            f"aidui-taxonomy.yaml not found at {target}; schema validation cannot run"
        )

    result = subprocess.run(
        ["bash", str(SCHEMA_CHECKER), str(target)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"check-corpus-schema.sh failed on aidui-taxonomy.yaml "
        f"(exit {result.returncode}).\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 9: check-corpus-schema passes on cognitive-load-checklist.yaml
# ---------------------------------------------------------------------------


def test_check_corpus_schema_passes_on_cognitive_load() -> None:
    """check-corpus-schema.sh must exit 0 on cognitive-load-checklist.yaml.

    RED: check-corpus-schema.sh does not exist yet — assertion FAILS before
    the GREEN task creates the script and the file.
    """
    if not SCHEMA_CHECKER.exists():
        pytest.fail(
            f"check-corpus-schema.sh not found at {SCHEMA_CHECKER}; "
            "schema validation cannot run"
        )

    target = PATTERNS_DIR / "cognitive-load-checklist.yaml"
    if not target.exists():
        pytest.fail(
            f"cognitive-load-checklist.yaml not found at {target}; "
            "schema validation cannot run"
        )

    result = subprocess.run(
        ["bash", str(SCHEMA_CHECKER), str(target)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"check-corpus-schema.sh failed on cognitive-load-checklist.yaml "
        f"(exit {result.returncode}).\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 10: ref-query returns >= 1 result for 'dark patterns' with domain: patterns
# ---------------------------------------------------------------------------


def test_ref_query_dark_patterns_returns_result_with_domain_patterns() -> None:
    """ref-query 'dark patterns' must return >= 1 result with domain: patterns.

    RED: ref-query.sh does not exist yet AND the patterns/ files do not exist —
    this assertion FAILS before the GREEN task creates the query tool and files.
    """
    if not REF_QUERY.exists():
        pytest.fail(f"ref-query.sh not found at {REF_QUERY}; ref-query cannot run")

    result = subprocess.run(
        ["bash", str(REF_QUERY), "dark patterns", "--domain", "patterns"],
        capture_output=True,
        text=True,
        timeout=30,
        cwd=str(REPO_ROOT),
    )
    assert result.returncode == 0, (
        f"ref-query.sh exited non-zero (exit {result.returncode}) "
        f"for query 'dark patterns' --domain patterns.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )

    output = result.stdout.strip()
    assert len(output) >= 1, (
        "ref-query returned no output for query 'dark patterns' --domain patterns; "
        "expected at least 1 result from Brignull taxonomy"
    )

    # The output must reference domain: patterns (not heuristics or principles)
    assert "patterns" in output.lower(), (
        f"ref-query output does not mention 'patterns' domain:\n{output}"
    )

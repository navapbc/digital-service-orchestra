"""RED-phase tests for plugins/dso/scripts/check-corpus-schema.py.

These tests MUST FAIL before check-corpus-schema.py exists.
Once the validator is implemented (GREEN phase), all tests must pass.

The validator:
  - Accepts YAML files with all required fields and valid tag vocabulary
  - Rejects files missing required fields (rule_id, prior_art, precedence, domain, title)
  - Rejects files with tag values not in the schema vocabulary
  - Rejects files with invalid YAML frontmatter (syntax errors)
  - Rejects files with unknown extra fields (strict mode)
  - Rejects empty files
  - Recursively validates files in subdirectories (rglob)
  - Supports --validate-index flag to check _index.yaml path resolution
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "check-corpus-schema.py"
SCHEMA_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "_schema.yaml"
REAL_CORPUS_DIR = REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference"


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------


def _run_validator(
    corpus_dir: Path,
    extra_args: list[str] | None = None,
) -> subprocess.CompletedProcess:
    """Run check-corpus-schema.py against a directory; always capture output."""
    cmd = [sys.executable, str(SCRIPT_PATH), str(corpus_dir)]
    if extra_args:
        cmd.extend(extra_args)
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
    )


def _write_schema(path: Path) -> None:
    """Write a minimal _schema.yaml with the 6 tag dimensions."""
    path.write_text(
        "tag_vocabulary:\n"
        "  domain:\n"
        "    - api\n"
        "    - ui\n"
        "    - data\n"
        "  component:\n"
        "    - ticket-cli\n"
        "    - hooks\n"
        "    - sprint\n"
        "  action:\n"
        "    - validate\n"
        "    - create\n"
        "    - update\n"
        "  compliance:\n"
        "    - tdd\n"
        "    - review-gate\n"
        "  severity:\n"
        "    - critical\n"
        "    - important\n"
        "    - minor\n"
        "  story_type:\n"
        "    - feature\n"
        "    - bug\n"
        "    - chore\n"
        "required_fields:\n"
        "  - rule_id\n"
        "  - title\n"
        "  - prior_art\n"
        "  - precedence\n"
        "  - domain\n"
    )


def _write_valid_entry(path: Path) -> None:
    """Write a schema-valid corpus entry YAML file."""
    path.write_text(
        "rule_id: TEST-001\n"
        "title: Test rule for schema validation\n"
        "prior_art: docs/adr/0001-example.md\n"
        "precedence: 1\n"
        "domain: api\n"
        "component: ticket-cli\n"
        "action: validate\n"
        "compliance: tdd\n"
        "severity: minor\n"
        "story_type: feature\n"
    )


# ---------------------------------------------------------------------------
# Test 1: Valid entry with all required fields exits 0
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_valid_entry_with_all_required_fields_passes(tmp_path: Path) -> None:
    """Given a YAML file with all required fields and valid tags,
    when the validator runs against it,
    then the exit code is 0.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()
    schema_file = corpus_dir / "_schema.yaml"
    _write_schema(schema_file)
    entry = corpus_dir / "test-rule.yaml"
    _write_valid_entry(entry)

    result = _run_validator(corpus_dir)
    assert result.returncode == 0, (
        f"Expected exit 0 for valid entry, got {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 2: Entry missing required 'title' field fails with non-zero exit
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_missing_required_field_title_fails(tmp_path: Path) -> None:
    """Given a YAML file missing the required 'title' field,
    when the validator runs against it,
    then the exit code is non-zero.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()
    _write_schema(corpus_dir / "_schema.yaml")
    entry = corpus_dir / "missing-title.yaml"
    entry.write_text(
        "rule_id: TEST-002\n"
        "prior_art: docs/adr/0001-example.md\n"
        "precedence: 1\n"
        "domain: api\n"
    )

    result = _run_validator(corpus_dir)
    assert result.returncode != 0, (
        f"Expected non-zero exit for missing 'title' field, got {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 3: Entry with invalid tag value fails
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_invalid_tag_value_not_in_schema_vocabulary_fails(tmp_path: Path) -> None:
    """Given a YAML file with a domain value not in the schema vocabulary,
    when the validator runs against it,
    then the exit code is non-zero.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()
    _write_schema(corpus_dir / "_schema.yaml")
    entry = corpus_dir / "bad-tag.yaml"
    entry.write_text(
        "rule_id: TEST-003\n"
        "title: Rule with invalid domain tag\n"
        "prior_art: docs/adr/0001-example.md\n"
        "precedence: 1\n"
        "domain: NOTADOMAIN\n"  # not in vocabulary
        "severity: minor\n"
        "story_type: feature\n"
    )

    result = _run_validator(corpus_dir)
    assert result.returncode != 0, (
        f"Expected non-zero exit for invalid tag 'NOTADOMAIN', got {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 4: Invalid YAML frontmatter (syntax error) fails
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_invalid_yaml_syntax_fails(tmp_path: Path) -> None:
    """Given a YAML file with a syntax error (tabs mixed with spaces),
    when the validator runs against it,
    then the exit code is non-zero.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()
    _write_schema(corpus_dir / "_schema.yaml")
    entry = corpus_dir / "bad-syntax.yaml"
    # Deliberate YAML syntax error: tab character breaks YAML parsing
    entry.write_bytes(b"rule_id: TEST-004\ntitle:\n\tbroken: indent\n")

    result = _run_validator(corpus_dir)
    assert result.returncode != 0, (
        f"Expected non-zero exit for YAML syntax error, got {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 5: Extra unknown field fails (strict mode)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_unknown_extra_field_fails_strict_mode(tmp_path: Path) -> None:
    """Given a YAML file with an unrecognized extra field,
    when the validator runs in strict mode,
    then the exit code is non-zero.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()
    _write_schema(corpus_dir / "_schema.yaml")
    entry = corpus_dir / "extra-field.yaml"
    entry.write_text(
        "rule_id: TEST-005\n"
        "title: Rule with extra unknown field\n"
        "prior_art: docs/adr/0001-example.md\n"
        "precedence: 1\n"
        "domain: api\n"
        "severity: minor\n"
        "story_type: feature\n"
        "unexpected_field: this_should_not_be_here\n"  # unknown field
    )

    result = _run_validator(corpus_dir)
    assert result.returncode != 0, (
        f"Expected non-zero exit for unknown extra field, got {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 6: Empty file fails
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_empty_file_fails(tmp_path: Path) -> None:
    """Given an empty YAML file,
    when the validator runs against it,
    then the exit code is non-zero.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()
    _write_schema(corpus_dir / "_schema.yaml")
    entry = corpus_dir / "empty.yaml"
    entry.write_text("")

    result = _run_validator(corpus_dir)
    assert result.returncode != 0, (
        f"Expected non-zero exit for empty file, got {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 7: Missing required 'rule_id' field fails
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_missing_required_field_rule_id_fails(tmp_path: Path) -> None:
    """Given a YAML file missing the required 'rule_id' field,
    when the validator runs against it,
    then the exit code is non-zero.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()
    _write_schema(corpus_dir / "_schema.yaml")
    entry = corpus_dir / "no-rule-id.yaml"
    entry.write_text(
        "title: Rule without an ID\n"
        "prior_art: docs/adr/0001-example.md\n"
        "precedence: 1\n"
        "domain: api\n"
    )

    result = _run_validator(corpus_dir)
    assert result.returncode != 0, (
        f"Expected non-zero exit for missing 'rule_id', got {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 8: Invalid severity tag value fails
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_invalid_severity_tag_fails(tmp_path: Path) -> None:
    """Given a YAML file with a severity value not in the schema vocabulary,
    when the validator runs against it,
    then the exit code is non-zero.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()
    _write_schema(corpus_dir / "_schema.yaml")
    entry = corpus_dir / "bad-severity.yaml"
    entry.write_text(
        "rule_id: TEST-008\n"
        "title: Rule with invalid severity\n"
        "prior_art: docs/adr/0001-example.md\n"
        "precedence: 1\n"
        "domain: api\n"
        "severity: blocker\n"  # not in vocabulary; valid are critical/important/minor
        "story_type: feature\n"
    )

    result = _run_validator(corpus_dir)
    assert result.returncode != 0, (
        f"Expected non-zero exit for invalid severity 'blocker', got {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 9: Recursive validation finds files in subdirectories
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_recursive_validation_finds_subdirectory_files(tmp_path: Path) -> None:
    """Given a corpus directory with a valid YAML file in a subdirectory,
    when the validator runs against the parent directory,
    then it finds and validates the subdirectory file and exits 0.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()
    schema_file = corpus_dir / "_schema.yaml"
    _write_schema(schema_file)

    # Place a valid entry in a subdirectory
    sub_dir = corpus_dir / "components"
    sub_dir.mkdir()
    entry = sub_dir / "sub-rule.yaml"
    _write_valid_entry(entry)

    result = _run_validator(corpus_dir)
    assert result.returncode == 0, (
        f"Expected exit 0 for valid subdirectory entry, got {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    # Verify the subdirectory file was actually found and validated
    assert "sub-rule.yaml" in result.stdout, (
        f"Expected 'sub-rule.yaml' to appear in validator output, "
        f"indicating it was found.\nstdout: {result.stdout}"
    )


# ---------------------------------------------------------------------------
# Test 10: --validate-index passes when all paths resolve (real corpus)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_validate_index_flag_passes(tmp_path: Path) -> None:
    """Given the real corpus directory with a valid _index.yaml,
    when the validator is run with --validate-index,
    then the exit code is 0 (all index paths resolve to existing files).
    """
    if not REAL_CORPUS_DIR.exists():
        pytest.skip(f"Real corpus directory not found: {REAL_CORPUS_DIR}")

    result = _run_validator(REAL_CORPUS_DIR, extra_args=["--validate-index"])
    assert result.returncode == 0, (
        f"Expected exit 0 with --validate-index against real corpus, "
        f"got {result.returncode}.\nstdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "_index.yaml path resolution" in result.stdout, (
        f"Expected _index.yaml path resolution check in output.\nstdout: {result.stdout}"
    )


# ---------------------------------------------------------------------------
# Test 11: --validate-index flag passes when _index.yaml is absent (skip silently)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_validate_index_flag_passes_when_index_absent(tmp_path: Path) -> None:
    """Given a corpus directory without an _index.yaml,
    when the validator is run with --validate-index,
    then the exit code is 0 (absent index is silently skipped).
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()
    schema_file = corpus_dir / "_schema.yaml"
    _write_schema(schema_file)
    entry = corpus_dir / "test-rule.yaml"
    _write_valid_entry(entry)

    # No _index.yaml created — should pass silently
    result = _run_validator(corpus_dir, extra_args=["--validate-index"])
    assert result.returncode == 0, (
        f"Expected exit 0 when --validate-index and _index.yaml is absent, "
        f"got {result.returncode}.\nstdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Test 12: Per-subdir _schema.yaml enforced over top-level schema
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_subdir_schema_enforced_over_toplevel_schema(tmp_path: Path) -> None:
    """Given a corpus where the top-level schema allows domain [a, b] but a
    subdir _schema.yaml only allows domain [a], when an entry in that subdir
    has domain b, then the validator exits non-zero (subdir schema is enforced).

    This test covers the direct _schema.yaml placement in the subdir.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()

    # Top-level schema: domain allows 'a' and 'b'
    top_schema = corpus_dir / "_schema.yaml"
    top_schema.write_text(
        "required_fields:\n  - title\ntag_vocabulary:\n  domain:\n    - a\n    - b\n"
    )

    subdir = corpus_dir / "narrow"
    subdir.mkdir()

    # Subdir schema: domain only allows 'a'
    sub_schema = subdir / "_schema.yaml"
    sub_schema.write_text(
        "required_fields:\n  - title\ntag_vocabulary:\n  domain:\n    - a\n"
    )

    # Entry in subdir with domain 'b' — valid top-level but invalid subdir schema
    entry = subdir / "entry.yaml"
    entry.write_text("title: Subdir entry\ndomain: b\n")

    result = _run_validator(corpus_dir)
    assert result.returncode != 0, (
        f"Expected non-zero exit: subdir schema restricts domain to [a], "
        f"but entry has domain 'b'. The top-level schema (which allows 'b') "
        f"must NOT override the subdir schema.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_sibling_schema_naming_convention_enforced(tmp_path: Path) -> None:
    """Given a corpus where a sibling _schema-{subdir}.yaml exists next to
    corpus_dir, when an entry in that subdir violates the sibling schema's
    narrower vocabulary, then the validator exits non-zero.

    This tests the _schema-{subdir_name}.yaml sibling-naming convention.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()

    # Top-level schema: domain allows 'a' and 'b'
    top_schema = corpus_dir / "_schema.yaml"
    top_schema.write_text(
        "required_fields:\n  - title\ntag_vocabulary:\n  domain:\n    - a\n    - b\n"
    )

    subdir = corpus_dir / "special"
    subdir.mkdir()

    # Sibling schema for 'special' subdir: domain only allows 'a'
    sibling_schema = corpus_dir / "_schema-special.yaml"
    sibling_schema.write_text(
        "required_fields:\n  - title\ntag_vocabulary:\n  domain:\n    - a\n"
    )

    # Entry in subdir with domain 'b' — valid top-level, invalid sibling schema
    entry = subdir / "entry.yaml"
    entry.write_text("title: Special subdir entry\ndomain: b\n")

    result = _run_validator(corpus_dir)
    assert result.returncode != 0, (
        f"Expected non-zero exit: sibling schema _schema-special.yaml restricts "
        f"domain to [a], but entry has domain 'b'. The top-level schema "
        f"(which allows 'b') must NOT be used for this subdir.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )

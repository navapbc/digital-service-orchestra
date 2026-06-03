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


# ---------------------------------------------------------------------------
# Test 13: _is_skip_file() helper skips expected filenames and prefixes
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_is_skip_file_matches_skip_names_and_prefix(tmp_path: Path) -> None:
    """_is_skip_file() must return True for _SKIP_NAMES entries and _schema-*.yaml
    prefix files, and False for normal corpus entry files.

    Imports the helper directly to verify its logic without running the full
    validator subprocess.
    """
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "check_corpus_schema", str(SCRIPT_PATH)
    )
    assert spec is not None and spec.loader is not None, (
        "Could not load check-corpus-schema.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    is_skip = mod._is_skip_file

    # Should be skipped — _SKIP_NAMES
    for name in (
        "_schema.yaml",
        "_schema-anti-patterns.yaml",
        "_index.yaml",
        "_overview.yaml",
    ):
        assert is_skip(Path(tmp_path / name)), (
            f"_is_skip_file() should return True for {name!r} (in _SKIP_NAMES)"
        )

    # Should be skipped — _schema-*.yaml prefix
    for name in ("_schema-foo.yaml", "_schema-special.yaml", "_schema-narrow.yaml"):
        assert is_skip(Path(tmp_path / name)), (
            f"_is_skip_file() should return True for {name!r} (matches _schema-* prefix)"
        )

    # Should NOT be skipped — normal entry files
    for name in ("entry.yaml", "my-rule.yaml", "schema.yaml", "index.yaml"):
        assert not is_skip(Path(tmp_path / name)), (
            f"_is_skip_file() should return False for {name!r} (normal corpus entry)"
        )


# ---------------------------------------------------------------------------
# Test 14: resolve_schema() priority — subdir _schema.yaml wins over sibling
#          _schema-<name>.yaml, which wins over top-level schema
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_resolve_schema_priority_subdir_over_sibling_over_toplevel(
    tmp_path: Path,
) -> None:
    """resolve_schema() must apply the documented priority order:
      1. entry.parent/_schema.yaml  (subdir-local)
      2. corpus_dir/_schema-{subdir}.yaml  (sibling naming)
      3. top-level corpus schema (fallback)

    Verified by using vocabularies that differ at each tier: the tightest
    vocabulary belongs to the highest-priority schema. A corpus entry that is
    valid under the top-level schema but invalid under the subdir schema must
    cause a non-zero exit when the subdir schema is present — confirming that
    priority 1 is honoured over priorities 2 and 3.
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()

    # Top-level (priority 3): domain allows a, b, c
    (corpus_dir / "_schema.yaml").write_text(
        "required_fields:\n  - title\ntag_vocabulary:\n  domain:\n    - a\n    - b\n    - c\n"
    )

    subdir = corpus_dir / "sub"
    subdir.mkdir()

    # Sibling schema (priority 2): domain allows a, b — NOT c
    (corpus_dir / "_schema-sub.yaml").write_text(
        "required_fields:\n  - title\ntag_vocabulary:\n  domain:\n    - a\n    - b\n"
    )

    # Subdir-local schema (priority 1): domain allows ONLY a
    (subdir / "_schema.yaml").write_text(
        "required_fields:\n  - title\ntag_vocabulary:\n  domain:\n    - a\n"
    )

    # Entry with domain 'b' — valid under top-level and sibling, INVALID under subdir
    (subdir / "entry.yaml").write_text("title: Entry\ndomain: b\n")

    result = _run_validator(corpus_dir)
    assert result.returncode != 0, (
        "Expected non-zero exit: subdir _schema.yaml (priority 1) restricts domain to [a] "
        "but entry has domain 'b'. The sibling _schema-sub.yaml (which allows 'b') and "
        "the top-level schema (which allows 'b') must NOT override the subdir schema.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )

    # Now remove the subdir _schema.yaml — priority 2 (sibling) should apply.
    # Entry domain 'b' is valid under sibling (a, b) so it should pass.
    (subdir / "_schema.yaml").unlink()
    result2 = _run_validator(corpus_dir)
    assert result2.returncode == 0, (
        "Expected exit 0 after removing subdir _schema.yaml: sibling _schema-sub.yaml "
        "(priority 2) allows domain 'b', so entry should be valid.\n"
        f"stdout: {result2.stdout}\nstderr: {result2.stderr}"
    )

    # Now remove the sibling schema — top-level (priority 3) should apply.
    # Entry domain 'b' is valid under top-level (a, b, c) so it should pass.
    (corpus_dir / "_schema-sub.yaml").unlink()
    result3 = _run_validator(corpus_dir)
    assert result3.returncode == 0, (
        "Expected exit 0 after removing sibling schema: top-level schema (priority 3) "
        "allows domain 'b', so entry should be valid.\n"
        f"stdout: {result3.stdout}\nstderr: {result3.stderr}"
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


# ---------------------------------------------------------------------------
# Test 16: Malformed subdir _schema.yaml (missing required keys) is handled
#          deterministically — falls back to top-level schema with a warning,
#          not silently used as-is.
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_malformed_subdir_schema_falls_back_to_toplevel_with_warning(
    tmp_path: Path,
) -> None:
    """Given a subdir whose _schema.yaml is malformed (has neither
    'required_fields' nor 'tag_vocabulary'), when the validator processes an
    entry in that subdir, then it emits a warning to stderr and falls back to
    the top-level schema rather than silently using the malformed schema.

    The entry is valid under the top-level schema, so the validator must exit 0
    (confirming the fallback is the top-level schema, not the broken one).
    """
    corpus_dir = tmp_path / "corpus"
    corpus_dir.mkdir()

    # Top-level schema: domain allows 'a' and 'b'
    (corpus_dir / "_schema.yaml").write_text(
        "required_fields:\n  - title\ntag_vocabulary:\n  domain:\n    - a\n    - b\n"
    )

    subdir = corpus_dir / "broken"
    subdir.mkdir()

    # Malformed subdir schema: contains neither 'required_fields' nor 'tag_vocabulary'
    (subdir / "_schema.yaml").write_text(
        "some_unrelated_key: not_a_schema\nanother_key: also_not_a_schema\n"
    )

    # Entry valid under top-level schema
    (subdir / "entry.yaml").write_text(
        "title: Entry in broken-schema subdir\ndomain: a\n"
    )

    result = _run_validator(corpus_dir)

    # Should not silently use the malformed schema — must emit a warning
    assert "malformed" in result.stderr.lower() or "WARNING" in result.stderr, (
        f"Expected a malformed-schema WARNING in stderr.\nstderr: {result.stderr}"
    )

    # Should fall back to top-level schema and pass (entry is valid under top-level)
    assert result.returncode == 0, (
        f"Expected exit 0 after falling back to top-level schema for malformed subdir "
        f"_schema.yaml. The entry is valid under the top-level schema.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )

"""RED tests for WCAG 2.2 AAA accessibility corpus entries.

These tests assert that YAML corpus files exist in
plugins/dso/data/ui-reference/accessibility/ covering all four WCAG 2.2
principles with correct compliance and action tags, that check-corpus-schema.sh
passes on those files, and that ref-query returns top results for the
'WCAG 2.2 keyboard navigation' precision query.

All tests FAIL (RED) before the GREEN task creates the corpus files.

Test: python3 -m pytest tests/scripts/test_corpus_accessibility_wcag.py -v
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

import pytest
import yaml

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
ACCESSIBILITY_DIR = (
    REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "accessibility"
)
INDEX_YAML = REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "_index.yaml"
CHECK_CORPUS_SCHEMA = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "check-corpus-schema.sh"
)
REF_QUERY = REPO_ROOT / "plugins" / "dso" / "scripts" / "ref-query.sh"

# The four WCAG 2.2 principles each require at least one corpus file.
REQUIRED_WCAG_PRINCIPLES = {"perceivable", "operable", "understandable", "robust"}

# Required tag values per Story DD coverage.
REQUIRED_COMPLIANCE_TAG = "wcag-2.2-aaa"
REQUIRED_KEYBOARD_ACTION_TAG = "keyboard-nav"

# Precision query for Story DD4.
REF_QUERY_STRING = "WCAG 2.2 keyboard navigation"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_yaml_file(path: Path) -> Any:
    """Load and return the parsed YAML document at *path*."""
    with path.open() as fh:
        return yaml.safe_load(fh)


def _yaml_files_in_accessibility_dir() -> list[Path]:
    """Return all .yaml files in the accessibility/ corpus directory."""
    if not ACCESSIBILITY_DIR.is_dir():
        return []
    return sorted(ACCESSIBILITY_DIR.glob("*.yaml"))


def _entry_compliance_tags(entry: dict[str, Any]) -> list[str]:
    """Extract compliance tag list from a corpus entry dict."""
    return list(entry.get("compliance", []))


def _entry_action_tags(entry: dict[str, Any]) -> list[str]:
    """Extract action tag list from a corpus entry dict."""
    return list(entry.get("action", []))


def _load_all_entries() -> list[dict[str, Any]]:
    """Load every YAML document from the accessibility/ corpus directory.

    Each file may be a single dict or a list of dicts (multi-document YAML).
    Returns a flat list of all entry dicts found.
    """
    entries: list[dict[str, Any]] = []
    for yaml_path in _yaml_files_in_accessibility_dir():
        doc = _load_yaml_file(yaml_path)
        if isinstance(doc, list):
            entries.extend(doc)
        elif isinstance(doc, dict):
            entries.append(doc)
    return entries


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestAccessibilityCorpusDirExists:
    """The accessibility/ directory must exist and contain YAML files."""

    def test_accessibility_directory_exists(self) -> None:
        """plugins/dso/data/ui-reference/accessibility/ must be a directory.

        FAILS in RED phase: directory does not exist before GREEN task.
        """
        assert ACCESSIBILITY_DIR.is_dir(), (
            f"Expected accessibility corpus directory to exist at {ACCESSIBILITY_DIR} "
            f"— create it in the GREEN task."
        )

    def test_accessibility_directory_contains_yaml_files(self) -> None:
        """accessibility/ must contain at least one .yaml file.

        FAILS in RED phase: directory does not exist before GREEN task.
        """
        yaml_files = _yaml_files_in_accessibility_dir()
        assert len(yaml_files) >= 1, (
            f"Expected at least one .yaml file in {ACCESSIBILITY_DIR}, found {len(yaml_files)}."
        )


class TestWcagPrinciplesCoverage:
    """Corpus files must cover all four WCAG 2.2 principles."""

    def test_all_four_wcag_principles_represented(self) -> None:
        """At least one YAML file name must include each of the four WCAG principles.

        FAILS in RED phase: directory does not exist, so no files are present.
        """
        yaml_files = _yaml_files_in_accessibility_dir()
        file_names_lower = {f.name.lower() for f in yaml_files}
        missing: list[str] = []
        for principle in REQUIRED_WCAG_PRINCIPLES:
            found = any(principle in name for name in file_names_lower)
            if not found:
                missing.append(principle)
        assert not missing, (
            f"Accessibility corpus is missing YAML files for WCAG principles: {missing}. "
            f"Expected filenames covering: {sorted(REQUIRED_WCAG_PRINCIPLES)}. "
            f"Found files: {sorted(file_names_lower) or '(none)'}."
        )


class TestComplianceTagWcagAaa:
    """All corpus entries must carry compliance: [wcag-2.2-aaa]."""

    def test_at_least_one_entry_has_wcag_aaa_compliance_tag(self) -> None:
        """At least one loaded corpus entry must have compliance: [wcag-2.2-aaa].

        FAILS in RED phase: no files exist, so no entries are loaded.
        """
        entries = _load_all_entries()
        assert entries, (
            f"No corpus entries found in {ACCESSIBILITY_DIR} — "
            "create accessibility YAML files in the GREEN task."
        )
        wcag_aaa_entries = [
            e for e in entries if REQUIRED_COMPLIANCE_TAG in _entry_compliance_tags(e)
        ]
        assert wcag_aaa_entries, (
            f"Expected at least one entry with compliance: [{REQUIRED_COMPLIANCE_TAG}], "
            f"but none of the {len(entries)} entries carry this tag. "
            f"Sample compliance tags seen: "
            f"{[_entry_compliance_tags(e) for e in entries[:3]]}."
        )

    def test_all_entries_have_wcag_aaa_compliance_tag(self) -> None:
        """Every corpus entry in accessibility/ must have compliance: [wcag-2.2-aaa].

        FAILS in RED phase: no files exist, so no entries are loaded.
        """
        entries = _load_all_entries()
        assert entries, f"No corpus entries found in {ACCESSIBILITY_DIR}."
        non_compliant = [
            e
            for e in entries
            if REQUIRED_COMPLIANCE_TAG not in _entry_compliance_tags(e)
        ]
        assert not non_compliant, (
            f"{len(non_compliant)} entries are missing compliance: [{REQUIRED_COMPLIANCE_TAG}]. "
            f"Offending rule_ids: "
            f"{[e.get('rule_id', '(no rule_id)') for e in non_compliant[:5]]}."
        )


class TestKeyboardNavActionTag:
    """Keyboard-navigation corpus entries must carry action: [keyboard-nav]."""

    def test_keyboard_nav_entries_have_action_tag(self) -> None:
        """Entries whose name or rule_id references keyboard navigation must carry action: [keyboard-nav].

        FAILS in RED phase: no files exist, so no entries are loaded.
        """
        entries = _load_all_entries()
        assert entries, f"No corpus entries found in {ACCESSIBILITY_DIR}."

        # Identify entries that are keyboard-navigation related by rule_id or domain context.
        # We look for entries that claim action: [keyboard-nav] or whose rule_id contains
        # "keyboard" — to verify the action tag is properly applied.
        keyboard_related = [
            e
            for e in entries
            if (
                "keyboard" in str(e.get("rule_id", "")).lower()
                or REQUIRED_KEYBOARD_ACTION_TAG in _entry_action_tags(e)
            )
        ]
        assert keyboard_related, (
            f"Expected at least one entry with action: [{REQUIRED_KEYBOARD_ACTION_TAG}] "
            f"or a keyboard-related rule_id in {ACCESSIBILITY_DIR}. "
            f"Found {len(entries)} total entries but none match keyboard-nav criteria. "
            f"Sample rule_ids: {[e.get('rule_id') for e in entries[:5]]}."
        )

        # All keyboard-related entries must carry the keyboard-nav action tag.
        keyboard_missing_tag = [
            e
            for e in keyboard_related
            if REQUIRED_KEYBOARD_ACTION_TAG not in _entry_action_tags(e)
        ]
        assert not keyboard_missing_tag, (
            f"{len(keyboard_missing_tag)} keyboard-navigation entries are missing "
            f"action: [{REQUIRED_KEYBOARD_ACTION_TAG}]. "
            f"Offending rule_ids: "
            f"{[e.get('rule_id', '(no rule_id)') for e in keyboard_missing_tag[:5]]}."
        )


class TestCheckCorpusSchemaScript:
    """check-corpus-schema.sh must exit 0 on all accessibility/ files."""

    def test_check_corpus_schema_script_exists(self) -> None:
        """plugins/dso/scripts/check-corpus-schema.sh must exist.

        FAILS in RED phase: script does not exist before GREEN task.
        """
        assert CHECK_CORPUS_SCHEMA.exists(), (
            f"Expected check-corpus-schema.sh at {CHECK_CORPUS_SCHEMA} — "
            "create this script in the GREEN task."
        )

    def test_check_corpus_schema_passes_on_accessibility_dir(self) -> None:
        """Running check-corpus-schema.sh on accessibility/ must exit 0.

        FAILS in RED phase: script does not exist and directory does not exist.
        """
        if not CHECK_CORPUS_SCHEMA.exists():
            pytest.fail(
                f"check-corpus-schema.sh not found at {CHECK_CORPUS_SCHEMA} — "
                "this is the expected RED state."
            )
        if not ACCESSIBILITY_DIR.is_dir():
            pytest.fail(
                f"accessibility/ directory not found at {ACCESSIBILITY_DIR} — "
                "this is the expected RED state."
            )
        result = subprocess.run(
            ["bash", str(CHECK_CORPUS_SCHEMA), str(ACCESSIBILITY_DIR)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"check-corpus-schema.sh exited {result.returncode} on {ACCESSIBILITY_DIR}.\n"
            f"stdout: {result.stdout!r}\n"
            f"stderr: {result.stderr!r}"
        )


class TestRefQueryPrecisionQuery:
    """ref-query.sh must return a top result with required tags for WCAG 2.2 keyboard navigation."""

    def test_ref_query_script_exists(self) -> None:
        """plugins/dso/scripts/ref-query.sh must exist.

        FAILS in RED phase: script does not exist before GREEN task.
        """
        assert REF_QUERY.exists(), (
            f"Expected ref-query.sh at {REF_QUERY} — "
            "create this script in the GREEN task."
        )

    def test_ref_query_wcag_keyboard_nav_returns_aaa_compliance_tag(self) -> None:
        """ref-query 'WCAG 2.2 keyboard navigation' top result must have compliance: [wcag-2.2-aaa].

        FAILS in RED phase: script does not exist and corpus does not exist.
        """
        if not REF_QUERY.exists():
            pytest.fail(
                f"ref-query.sh not found at {REF_QUERY} — this is the expected RED state."
            )
        result = subprocess.run(
            ["bash", str(REF_QUERY), "--top-n", "1", REF_QUERY_STRING],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"ref-query.sh exited {result.returncode} for query {REF_QUERY_STRING!r}.\n"
            f"stdout: {result.stdout!r}\n"
            f"stderr: {result.stderr!r}"
        )
        output = result.stdout
        assert REQUIRED_COMPLIANCE_TAG in output, (
            f"Expected top ref-query result for {REF_QUERY_STRING!r} to contain "
            f"'{REQUIRED_COMPLIANCE_TAG}' in output, but got:\n{output!r}"
        )

    def test_ref_query_wcag_keyboard_nav_returns_keyboard_nav_action_tag(self) -> None:
        """ref-query 'WCAG 2.2 keyboard navigation' top result must have action: [keyboard-nav].

        FAILS in RED phase: script does not exist and corpus does not exist.
        """
        if not REF_QUERY.exists():
            pytest.fail(
                f"ref-query.sh not found at {REF_QUERY} — this is the expected RED state."
            )
        result = subprocess.run(
            ["bash", str(REF_QUERY), "--top-n", "1", REF_QUERY_STRING],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"ref-query.sh exited {result.returncode} for query {REF_QUERY_STRING!r}.\n"
            f"stdout: {result.stdout!r}\n"
            f"stderr: {result.stderr!r}"
        )
        output = result.stdout
        assert REQUIRED_KEYBOARD_ACTION_TAG in output, (
            f"Expected top ref-query result for {REF_QUERY_STRING!r} to contain "
            f"'{REQUIRED_KEYBOARD_ACTION_TAG}' in output, but got:\n{output!r}"
        )

    def test_ref_query_wcag_keyboard_nav_returns_both_required_tags(self) -> None:
        """ref-query top result must have BOTH compliance: [wcag-2.2-aaa] AND action: [keyboard-nav].

        FAILS in RED phase: script and corpus do not exist.
        """
        if not REF_QUERY.exists():
            pytest.fail(
                f"ref-query.sh not found at {REF_QUERY} — this is the expected RED state."
            )
        result = subprocess.run(
            ["bash", str(REF_QUERY), "--top-n", "1", REF_QUERY_STRING],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"ref-query.sh exited {result.returncode} for query {REF_QUERY_STRING!r}.\n"
            f"stdout: {result.stdout!r}\n"
            f"stderr: {result.stderr!r}"
        )
        output = result.stdout
        has_compliance = REQUIRED_COMPLIANCE_TAG in output
        has_action = REQUIRED_KEYBOARD_ACTION_TAG in output
        assert has_compliance and has_action, (
            f"Top result for query {REF_QUERY_STRING!r} is missing required tags.\n"
            f"  compliance: [{REQUIRED_COMPLIANCE_TAG}] present={has_compliance}\n"
            f"  action: [{REQUIRED_KEYBOARD_ACTION_TAG}] present={has_action}\n"
            f"  full output: {output!r}"
        )

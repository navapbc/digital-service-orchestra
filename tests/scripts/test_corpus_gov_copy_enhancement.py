"""RED tests for gov-copy Enhancement corpus entries (18F, FPLG, CDC).

These tests assert that YAML corpus files exist in
plugins/dso/data/ui-reference/gov-copy/ covering 18F Plain Language guide,
Federal Plain Language Guidelines (Plain Writing Act of 2010), and CDC
reading-level guidance, that check-corpus-schema.py passes, and that
ref-query.sh returns a result for the 'reading level' precision query.

All tests FAIL (RED) before the GREEN task creates the corpus files.

Test: python3 -m pytest tests/scripts/test_corpus_gov_copy_enhancement.py -v
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
GOV_COPY_DIR = REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "gov-copy"
SCHEMA_YAML = REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "_schema.yaml"
CHECK_CORPUS_SCHEMA = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "check-corpus-schema.py"
)
REF_QUERY = REPO_ROOT / "plugins" / "dso" / "scripts" / "ref-query.sh"
UI_REFERENCE_SOURCES = REPO_ROOT / "docs" / "ui-reference-sources.yaml"

# Required domain tag on every new entry.
REQUIRED_DOMAIN = "gov-copy"

# Source files that must be present (name fragment → description).
REQUIRED_SOURCES = {
    "18f": "18F Plain Language guide",
    "federal-plain-language": "Federal Plain Language Guidelines",
    "cdc": "CDC reading-level guidance",
}

# Precision query for Story DD5.
REF_QUERY_STRING = "reading level"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_yaml_entries(path: Path) -> list[dict[str, Any]]:
    """Load all YAML documents from *path*, handling multi-doc files."""
    entries: list[dict[str, Any]] = []
    with path.open() as fh:
        for doc in yaml.safe_load_all(fh):
            if doc is None:
                continue
            if isinstance(doc, list):
                for item in doc:
                    if isinstance(item, dict):
                        entries.append(item)
            elif isinstance(doc, dict):
                entries.append(doc)
    return entries


def _corpus_yaml_files() -> list[Path]:
    """Return corpus .yaml files in gov-copy/ (excluding meta files)."""
    if not GOV_COPY_DIR.is_dir():
        return []
    excluded = {"_schema.yaml", "_index.yaml", "_schema-anti-patterns.yaml"}
    return sorted(p for p in GOV_COPY_DIR.glob("*.yaml") if p.name not in excluded)


def _enhancement_yaml_files() -> list[Path]:
    """Return only Enhancement-slice files (18f, federal-plain-language, cdc)."""
    return [
        f
        for f in _corpus_yaml_files()
        if any(k in f.name.lower() for k in REQUIRED_SOURCES)
    ]


def _load_enhancement_entries() -> list[dict[str, Any]]:
    """Load every entry from Enhancement-slice corpus files."""
    entries: list[dict[str, Any]] = []
    for yaml_path in _enhancement_yaml_files():
        entries.extend(_load_yaml_entries(yaml_path))
    return entries


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestGovCopyEnhancementFilesExist:
    """Files for 18F, FPLG, and CDC source partitions must exist."""

    def test_18f_file_exists(self) -> None:
        """A YAML file for 18F Plain Language must exist in gov-copy/.

        FAILS in RED phase: file does not exist before GREEN task.
        """
        if not GOV_COPY_DIR.is_dir():
            pytest.fail(f"gov-copy/ directory not found at {GOV_COPY_DIR} — RED state.")
        files_18f = [f for f in _corpus_yaml_files() if "18f" in f.name.lower()]
        assert files_18f, (
            f"No 18F-related YAML file found in {GOV_COPY_DIR}. "
            "Expected a file whose name contains '18f' (e.g., 18f-plain-language.yaml)."
        )

    def test_fplg_file_exists(self) -> None:
        """A YAML file for FPLG must exist in gov-copy/.

        FAILS in RED phase: file does not exist before GREEN task.
        """
        if not GOV_COPY_DIR.is_dir():
            pytest.fail(f"gov-copy/ directory not found at {GOV_COPY_DIR} — RED state.")
        fplg_files = [
            f
            for f in _corpus_yaml_files()
            if "federal-plain-language" in f.name.lower()
        ]
        assert fplg_files, (
            f"No FPLG-related YAML file found in {GOV_COPY_DIR}. "
            "Expected a file whose name contains 'federal-plain-language'."
        )

    def test_cdc_file_exists(self) -> None:
        """A YAML file for CDC reading-level guidance must exist in gov-copy/.

        FAILS in RED phase: file does not exist before GREEN task.
        """
        if not GOV_COPY_DIR.is_dir():
            pytest.fail(f"gov-copy/ directory not found at {GOV_COPY_DIR} — RED state.")
        cdc_files = [f for f in _corpus_yaml_files() if "cdc" in f.name.lower()]
        assert cdc_files, (
            f"No CDC-related YAML file found in {GOV_COPY_DIR}. "
            "Expected a file whose name contains 'cdc'."
        )


class TestGovCopyEnhancementRequiredFields:
    """Every Enhancement entry must have domain, prior_art, and precedence."""

    def test_all_entries_have_domain_gov_copy(self) -> None:
        """Every Enhancement corpus entry must have domain: [gov-copy].

        FAILS in RED phase: no files exist before GREEN task.
        """
        entries = _load_enhancement_entries()
        assert entries, (
            "No Enhancement corpus entries found (18F/FPLG/CDC) — "
            "create them in the GREEN task."
        )
        wrong: list[dict[str, Any]] = []
        for entry in entries:
            domain = entry.get("domain", [])
            if isinstance(domain, str):
                domain = [domain]
            if REQUIRED_DOMAIN not in domain:
                wrong.append(entry)
        assert not wrong, (
            f"{len(wrong)} entries missing domain: [{REQUIRED_DOMAIN}]. "
            f"IDs: {[e.get('id', '?') for e in wrong[:5]]}"
        )

    def test_all_entries_have_prior_art_and_precedence(self) -> None:
        """Every Enhancement entry must have prior_art and precedence fields.

        FAILS in RED phase: no files exist before GREEN task.
        """
        entries = _load_enhancement_entries()
        assert entries, (
            "No Enhancement corpus entries found (18F/FPLG/CDC) — "
            "create them in the GREEN task."
        )
        missing: list[str] = []
        for entry in entries:
            eid = entry.get("id", "(no id)")
            if not entry.get("prior_art"):
                missing.append(f"{eid}: missing prior_art")
            if "precedence" not in entry:
                missing.append(f"{eid}: missing precedence")
        assert not missing, (
            "Required fields absent from Enhancement entries:\n" + "\n".join(missing)
        )


class TestGovCopyEnhancementSchemaValidity:
    """check-corpus-schema.py must exit 0 on all gov-copy/ files."""

    def test_all_entries_are_schema_valid(self) -> None:
        """Running check-corpus-schema.py on gov-copy/ must exit 0.

        FAILS in RED phase: no Enhancement files exist before GREEN task.
        """
        if not _enhancement_yaml_files():
            pytest.fail(
                "No Enhancement YAML files (18F/FPLG/CDC) found in "
                f"{GOV_COPY_DIR} — RED state."
            )
        result = subprocess.run(
            [
                "python3",
                str(CHECK_CORPUS_SCHEMA),
                str(GOV_COPY_DIR),
                "--schema",
                str(SCHEMA_YAML),
            ],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"check-corpus-schema.py exited {result.returncode} on {GOV_COPY_DIR}.\n"
            f"stdout: {result.stdout!r}\n"
            f"stderr: {result.stderr!r}"
        )


class TestGovCopyEnhancementSourcesYaml:
    """docs/ui-reference-sources.yaml must register 18F, FPLG, and CDC."""

    def test_sources_yaml_registers_all_three(self) -> None:
        """18F, FPLG, and CDC must appear as sources in docs/ui-reference-sources.yaml.

        FAILS in RED phase: entries not yet added before GREEN task.
        """
        if not UI_REFERENCE_SOURCES.exists():
            pytest.fail(
                f"docs/ui-reference-sources.yaml not found at {UI_REFERENCE_SOURCES}"
            )
        content = UI_REFERENCE_SOURCES.read_text(encoding="utf-8").lower()
        missing = []
        if "18f" not in content:
            missing.append("18F")
        if (
            "federal plain language" not in content
            and "plain writing act" not in content
        ):
            missing.append("FPLG (Federal Plain Language Guidelines)")
        if "cdc" not in content:
            missing.append("CDC")
        assert not missing, (
            "docs/ui-reference-sources.yaml is missing entries for: "
            + ", ".join(missing)
        )


class TestGovCopyEnhancementRefQuery:
    """ref-query.sh must return a gov-copy result for 'reading level'."""

    def test_ref_query_returns_reading_level_result(self) -> None:
        """ref-query.sh 'reading level' must return at least one gov-copy result.

        FAILS in RED phase: Enhancement files don't exist before GREEN task.
        """
        if not _enhancement_yaml_files():
            pytest.fail("No Enhancement YAML files (18F/FPLG/CDC) found — RED state.")
        if not REF_QUERY.exists():
            pytest.fail(f"ref-query.sh not found at {REF_QUERY} — RED state.")
        result = subprocess.run(
            ["bash", str(REF_QUERY), "--top-n", "5", REF_QUERY_STRING],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"ref-query.sh exited {result.returncode} for query {REF_QUERY_STRING!r}.\n"
            f"stdout: {result.stdout!r}\n"
            f"stderr: {result.stderr!r}"
        )
        output = result.stdout
        assert REQUIRED_DOMAIN in output, (
            f"Expected ref-query result for {REF_QUERY_STRING!r} to contain "
            f"'{REQUIRED_DOMAIN}' entries, but got:\n{output!r}"
        )

"""RED tests for gov-copy Foundation corpus entries (USWDS, GOV.UK, VA.gov).

These tests assert that YAML corpus files exist in
plugins/dso/data/ui-reference/gov-copy/ covering USWDS forms copy, GOV.UK
error/form/Service-Manual patterns, and VA.gov Content Style Guide, that
check-corpus-schema.py passes on those files, and that ref-query.sh returns
a result for the 'form error message' precision query.

All tests FAIL (RED) before the GREEN task creates the corpus files.

Test: python3 -m pytest tests/scripts/test_corpus_gov_copy_foundation.py -v
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

# Required domain tag on every entry.
REQUIRED_DOMAIN = "gov-copy"

# Source partitions that must be present.
REQUIRED_SOURCE_PARTITIONS = ["uswds", "govuk", "vagov"]

# Precision query for Story DD6.
REF_QUERY_STRING = "form error message"


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


def _load_all_entries() -> list[dict[str, Any]]:
    """Load every entry from gov-copy/ corpus files."""
    entries: list[dict[str, Any]] = []
    for yaml_path in _corpus_yaml_files():
        entries.extend(_load_yaml_entries(yaml_path))
    return entries


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestGovCopyDirectoryExists:
    """The gov-copy/ directory must exist."""

    def test_gov_copy_directory_exists(self) -> None:
        """plugins/dso/data/ui-reference/gov-copy/ must be a directory.

        FAILS in RED phase: directory does not exist before GREEN task.
        """
        assert GOV_COPY_DIR.is_dir(), (
            f"Expected gov-copy corpus directory to exist at {GOV_COPY_DIR} — "
            "create it in the GREEN task."
        )


class TestGovCopySourcePartitions:
    """Files for USWDS, GOV.UK, and VA.gov source partitions must exist."""

    def test_uswds_partition_file_exists(self) -> None:
        """A YAML file for the USWDS source partition must exist in gov-copy/.

        FAILS in RED phase: directory does not exist before GREEN task.
        """
        if not GOV_COPY_DIR.is_dir():
            pytest.fail(f"gov-copy/ directory not found at {GOV_COPY_DIR} — RED state.")
        uswds_files = [f for f in _corpus_yaml_files() if "uswds" in f.name.lower()]
        assert uswds_files, (
            f"No USWDS-related YAML file found in {GOV_COPY_DIR}. "
            "Expected a file whose name contains 'uswds' (e.g., uswds-forms-copy.yaml)."
        )

    def test_govuk_partition_file_exists(self) -> None:
        """A YAML file for the GOV.UK source partition must exist in gov-copy/.

        FAILS in RED phase: directory does not exist before GREEN task.
        """
        if not GOV_COPY_DIR.is_dir():
            pytest.fail(f"gov-copy/ directory not found at {GOV_COPY_DIR} — RED state.")
        govuk_files = [f for f in _corpus_yaml_files() if "govuk" in f.name.lower()]
        assert govuk_files, (
            f"No GOV.UK-related YAML file found in {GOV_COPY_DIR}. "
            "Expected a file whose name contains 'govuk'."
        )

    def test_vagov_partition_file_exists(self) -> None:
        """A YAML file for the VA.gov source partition must exist in gov-copy/.

        FAILS in RED phase: directory does not exist before GREEN task.
        """
        if not GOV_COPY_DIR.is_dir():
            pytest.fail(f"gov-copy/ directory not found at {GOV_COPY_DIR} — RED state.")
        vagov_files = [f for f in _corpus_yaml_files() if "vagov" in f.name.lower()]
        assert vagov_files, (
            f"No VA.gov-related YAML file found in {GOV_COPY_DIR}. "
            "Expected a file whose name contains 'vagov'."
        )


class TestGovCopyDomainTag:
    """Every entry must carry domain: [gov-copy]."""

    def test_all_entries_have_domain_gov_copy(self) -> None:
        """Every corpus entry must have domain: [gov-copy].

        FAILS in RED phase: no files exist, so no entries are loaded.
        """
        entries = _load_all_entries()
        assert entries, (
            f"No corpus entries found in {GOV_COPY_DIR} — "
            "create gov-copy YAML files in the GREEN task."
        )
        wrong_domain: list[dict[str, Any]] = []
        for entry in entries:
            domain = entry.get("domain", [])
            if isinstance(domain, str):
                domain = [domain]
            if REQUIRED_DOMAIN not in domain:
                wrong_domain.append(entry)
        assert not wrong_domain, (
            f"{len(wrong_domain)} entries are missing domain: [{REQUIRED_DOMAIN}]. "
            f"Offending ids: {[e.get('id', '(no id)') for e in wrong_domain[:5]]}."
        )


class TestGovCopySchemaValidity:
    """check-corpus-schema.py must exit 0 on all gov-copy/ files."""

    def test_all_entries_are_schema_valid(self) -> None:
        """Running check-corpus-schema.py on gov-copy/ must exit 0.

        FAILS in RED phase: directory does not exist before GREEN task.
        """
        if not GOV_COPY_DIR.is_dir():
            pytest.fail(f"gov-copy/ directory not found at {GOV_COPY_DIR} — RED state.")
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


class TestGovCopyRefQuery:
    """ref-query.sh must return a gov-copy result for 'form error message'."""

    def test_ref_query_returns_gov_copy_result(self) -> None:
        """ref-query.sh 'form error message' must return at least one gov-copy result.

        FAILS in RED phase: corpus does not exist before GREEN task.
        """
        if not GOV_COPY_DIR.is_dir():
            pytest.fail(f"gov-copy/ directory not found at {GOV_COPY_DIR} — RED state.")
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

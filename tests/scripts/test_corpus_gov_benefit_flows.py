"""RED tests for gov-benefit-flows UI/UX corpus entries.

These tests assert that YAML corpus files exist in
plugins/dso/data/ui-reference/gov-benefit-flows/ covering government benefit
application form patterns and SNAP policy context, that check-corpus-schema.py
passes on those files, and that ref-query.sh returns a result for the
'one-question-per-page' precision query.

All tests FAIL (RED) before the GREEN task creates the corpus files.

Test: python3 -m pytest tests/scripts/test_corpus_gov_benefit_flows.py -v
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
GOV_BENEFIT_FLOWS_DIR = (
    REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "gov-benefit-flows"
)
SCHEMA_YAML = REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "_schema.yaml"
CHECK_CORPUS_SCHEMA = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "check-corpus-schema.py"
)
REF_QUERY = REPO_ROOT / "plugins" / "dso" / "scripts" / "ref-query.sh"

# Minimum number of corpus YAML files required (excludes _schema.yaml, _index.yaml).
MIN_FILE_COUNT = 11

# Required domain tag on every entry.
REQUIRED_DOMAIN = "gov-benefit-flows"

# Precision query for Story DD4.
REF_QUERY_STRING = "one-question-per-page"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_yaml_file(path: Path) -> Any:
    """Load and return the parsed YAML document at *path*."""
    with path.open() as fh:
        return yaml.safe_load(fh)


def _corpus_yaml_files() -> list[Path]:
    """Return all corpus .yaml files in gov-benefit-flows/ (excluding meta files)."""
    if not GOV_BENEFIT_FLOWS_DIR.is_dir():
        return []
    excluded = {"_schema.yaml", "_index.yaml", "_schema-anti-patterns.yaml"}
    return sorted(
        p for p in GOV_BENEFIT_FLOWS_DIR.glob("*.yaml") if p.name not in excluded
    )


def _load_all_entries() -> list[dict[str, Any]]:
    """Load every YAML document from the gov-benefit-flows/ corpus directory.

    Each file may be a single dict or a list of dicts.
    Returns a flat list of all entry dicts found.
    """
    entries: list[dict[str, Any]] = []
    for yaml_path in _corpus_yaml_files():
        doc = _load_yaml_file(yaml_path)
        if isinstance(doc, list):
            entries.extend(doc)
        elif isinstance(doc, dict):
            entries.append(doc)
    return entries


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestGovBenefitFlowsDirectoryExists:
    """The gov-benefit-flows/ directory must exist."""

    def test_gov_benefit_flows_directory_exists(self) -> None:
        """plugins/dso/data/ui-reference/gov-benefit-flows/ must be a directory.

        FAILS in RED phase: directory does not exist before GREEN task.
        """
        assert GOV_BENEFIT_FLOWS_DIR.is_dir(), (
            f"Expected gov-benefit-flows corpus directory to exist at "
            f"{GOV_BENEFIT_FLOWS_DIR} — create it in the GREEN task."
        )


class TestGovBenefitFlowsFileCount:
    """The gov-benefit-flows/ directory must contain at least 11 YAML files."""

    def test_gov_benefit_flows_has_at_least_11_yaml_files(self) -> None:
        """gov-benefit-flows/ must contain >=11 corpus .yaml files (excl. meta files).

        FAILS in RED phase: directory does not exist before GREEN task.
        """
        yaml_files = _corpus_yaml_files()
        assert len(yaml_files) >= MIN_FILE_COUNT, (
            f"Expected at least {MIN_FILE_COUNT} .yaml files in "
            f"{GOV_BENEFIT_FLOWS_DIR}, found {len(yaml_files)}. "
            "Create the corpus files in the GREEN task."
        )


class TestGovBenefitFlowsDomainTag:
    """Every entry must carry domain: [gov-benefit-flows]."""

    def test_all_entries_have_domain_gov_benefit_flows(self) -> None:
        """Every corpus entry must have domain: [gov-benefit-flows].

        FAILS in RED phase: no files exist, so no entries are loaded.
        """
        entries = _load_all_entries()
        assert entries, (
            f"No corpus entries found in {GOV_BENEFIT_FLOWS_DIR} — "
            "create gov-benefit-flows YAML files in the GREEN task."
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


class TestGovBenefitFlowsSchemaValidity:
    """check-corpus-schema.py must exit 0 on all gov-benefit-flows/ files."""

    def test_all_entries_are_schema_valid(self) -> None:
        """Running check-corpus-schema.py on gov-benefit-flows/ must exit 0.

        FAILS in RED phase: directory does not exist before GREEN task.
        """
        if not GOV_BENEFIT_FLOWS_DIR.is_dir():
            pytest.fail(
                f"gov-benefit-flows/ directory not found at {GOV_BENEFIT_FLOWS_DIR} — "
                "this is the expected RED state."
            )
        result = subprocess.run(
            [
                "python3",
                str(CHECK_CORPUS_SCHEMA),
                str(GOV_BENEFIT_FLOWS_DIR),
                "--schema",
                str(SCHEMA_YAML),
            ],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"check-corpus-schema.py exited {result.returncode} on "
            f"{GOV_BENEFIT_FLOWS_DIR}.\n"
            f"stdout: {result.stdout!r}\n"
            f"stderr: {result.stderr!r}"
        )


class TestGovBenefitFlowsRefQuery:
    """ref-query.sh must return a gov-benefit-flows result for 'one-question-per-page'."""

    def test_ref_query_returns_gov_benefit_flows_result(self) -> None:
        """ref-query.sh 'one-question-per-page' must return at least one result.

        FAILS in RED phase: corpus does not exist before GREEN task.
        """
        if not REF_QUERY.exists():
            pytest.fail(
                f"ref-query.sh not found at {REF_QUERY} — "
                "this is the expected RED state."
            )
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
        assert REQUIRED_DOMAIN in output or "one-question" in output.lower(), (
            f"Expected ref-query result for {REF_QUERY_STRING!r} to contain "
            f"'{REQUIRED_DOMAIN}' or 'one-question' content, but got:\n{output!r}"
        )

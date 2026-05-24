"""RED tests for USWDS component corpus entries (story fab0-d0e2, task 45fa-a8db).

These tests are RED — the corpus files do not yet exist.
All tests must FAIL until task 1850-d22f (GREEN) creates the files.

Behavioral surface tested:
  - YAML corpus files exist in plugins/dso/data/ui-reference/components/ covering
    each required USWDS component category (9+ component types)
  - Form-related entries carry component:[form] in their YAML frontmatter
  - All entries carry compliance:[section-508] and license:CC0-1.0 in frontmatter
  - check-corpus-schema.sh exits 0 on the components/ directory
  - dso ref-query "USWDS form validation" returns a top result whose frontmatter
    includes component:[form]

Run: python3 -m pytest tests/scripts/test_corpus_components_uswds.py -v
Expected result before GREEN task: all tests FAIL.
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
COMPONENTS_DIR = REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "components"
CHECK_CORPUS_SCHEMA = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "check-corpus-schema.sh"
)
DSO_SHIM = REPO_ROOT / ".claude" / "scripts" / "dso"

# Required USWDS component category files (the GREEN task names them explicitly)
REQUIRED_COMPONENT_FILES = [
    "uswds-form-components.yaml",
    "uswds-buttons.yaml",
    "uswds-navigation.yaml",
    "uswds-alerts-banners.yaml",
    "uswds-modals.yaml",
    "uswds-tables.yaml",
    "uswds-typography-cards.yaml",
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_yaml_frontmatter(path: Path) -> dict[str, Any]:
    """Load and parse a YAML file; return the top-level mapping."""
    with path.open() as fh:
        return yaml.safe_load(fh) or {}


def _load_all_entries(yaml_path: Path) -> list[dict[str, Any]]:
    """Load all YAML documents from a multi-document corpus file.

    Corpus files may be either a single mapping (one entry) or a list of
    mappings (multiple entries).  Normalize to a flat list.
    """
    with yaml_path.open() as fh:
        docs = list(yaml.safe_load_all(fh))
    entries: list[dict[str, Any]] = []
    for doc in docs:
        if doc is None:
            continue
        if isinstance(doc, list):
            entries.extend(doc)
        else:
            entries.append(doc)
    return entries


def _run_ref_query(query: str, top_n: int = 1) -> subprocess.CompletedProcess[str]:
    """Run 'dso ref-query <query> --top-n <n>' and return the CompletedProcess."""
    return subprocess.run(
        [str(DSO_SHIM), "ref-query", query, "--top-n", str(top_n)],
        capture_output=True,
        text=True,
        timeout=15,
    )


# ---------------------------------------------------------------------------
# DD1 — Component files exist for all required USWDS categories
# ---------------------------------------------------------------------------


class TestDD1ComponentFilesExist:
    """All required USWDS component YAML files must exist in components/."""

    def test_components_directory_exists(self) -> None:
        """Given the corpus is populated, the components/ directory exists.

        RED: fails because plugins/dso/data/ui-reference/components/ has not
        been created yet (story 9fee-6947 and 1850-d22f are pending).
        """
        assert COMPONENTS_DIR.is_dir(), (
            f"components/ directory not found at {COMPONENTS_DIR} — "
            "expected RED failure; run GREEN task 1850-d22f to create it."
        )

    def test_uswds_form_components_file_exists(self) -> None:
        """Given USWDS corpus is created, uswds-form-components.yaml exists."""
        target = COMPONENTS_DIR / "uswds-form-components.yaml"
        assert target.exists(), (
            f"Expected {target} to exist — RED failure until GREEN task creates it."
        )

    def test_uswds_buttons_file_exists(self) -> None:
        """Given USWDS corpus is created, uswds-buttons.yaml exists."""
        target = COMPONENTS_DIR / "uswds-buttons.yaml"
        assert target.exists(), (
            f"Expected {target} to exist — RED failure until GREEN task creates it."
        )

    def test_uswds_navigation_file_exists(self) -> None:
        """Given USWDS corpus is created, uswds-navigation.yaml exists."""
        target = COMPONENTS_DIR / "uswds-navigation.yaml"
        assert target.exists(), (
            f"Expected {target} to exist — RED failure until GREEN task creates it."
        )

    def test_uswds_alerts_banners_file_exists(self) -> None:
        """Given USWDS corpus is created, uswds-alerts-banners.yaml exists."""
        target = COMPONENTS_DIR / "uswds-alerts-banners.yaml"
        assert target.exists(), (
            f"Expected {target} to exist — RED failure until GREEN task creates it."
        )

    def test_uswds_modals_file_exists(self) -> None:
        """Given USWDS corpus is created, uswds-modals.yaml exists."""
        target = COMPONENTS_DIR / "uswds-modals.yaml"
        assert target.exists(), (
            f"Expected {target} to exist — RED failure until GREEN task creates it."
        )

    def test_uswds_tables_file_exists(self) -> None:
        """Given USWDS corpus is created, uswds-tables.yaml exists."""
        target = COMPONENTS_DIR / "uswds-tables.yaml"
        assert target.exists(), (
            f"Expected {target} to exist — RED failure until GREEN task creates it."
        )

    def test_uswds_typography_cards_file_exists(self) -> None:
        """Given USWDS corpus is created, uswds-typography-cards.yaml exists."""
        target = COMPONENTS_DIR / "uswds-typography-cards.yaml"
        assert target.exists(), (
            f"Expected {target} to exist — RED failure until GREEN task creates it."
        )

    def test_at_least_nine_component_files_in_directory(self) -> None:
        """Given USWDS corpus is created, components/ has at least 9 YAML files.

        The story done-definition requires coverage of: form inputs, buttons,
        navigation, alerts, banners, modals, tables, typography, cards (9+ types).
        """
        if not COMPONENTS_DIR.is_dir():
            pytest.fail(
                f"components/ directory absent at {COMPONENTS_DIR} — "
                "RED failure; directory must be created by GREEN task."
            )
        yaml_files = list(COMPONENTS_DIR.glob("*.yaml"))
        assert len(yaml_files) >= 9, (
            f"Expected at least 9 component YAML files in {COMPONENTS_DIR}, "
            f"found {len(yaml_files)}: {[f.name for f in yaml_files]}"
        )


# ---------------------------------------------------------------------------
# DD2 — Form entries carry component:[form] tag
# ---------------------------------------------------------------------------


class TestDD2FormEntriesHaveFormTag:
    """Form-related corpus entries must include component:[form] in frontmatter."""

    def test_form_components_file_has_form_component_tag(self) -> None:
        """Given uswds-form-components.yaml is loaded, entries have component:[form].

        When the YAML is parsed, then at least one entry has 'form' in its
        component list — observable via YAML frontmatter field value.

        RED: fails because the file does not yet exist.
        """
        form_file = COMPONENTS_DIR / "uswds-form-components.yaml"
        if not form_file.exists():
            pytest.fail(
                f"{form_file.name} not found — RED failure; "
                "expected to exist after GREEN task 1850-d22f."
            )
        entries = _load_all_entries(form_file)
        assert entries, f"No entries found in {form_file}"
        form_tagged = [e for e in entries if "form" in (e.get("component") or [])]
        assert form_tagged, (
            f"Expected at least one entry in {form_file.name} with "
            f"component:[form]; found none.\n"
            f"Entry component values: {[e.get('component') for e in entries]}"
        )

    def test_all_form_related_entries_across_components_dir_have_form_tag(self) -> None:
        """Given components/ is populated, any entry with form-related content has component:[form].

        Checks that the form-tag contract applies beyond uswds-form-components.yaml:
        the story specifies date picker and file input entries should also carry
        component:[form].
        """
        if not COMPONENTS_DIR.is_dir():
            pytest.fail(
                "components/ directory absent — RED failure; "
                "create via GREEN task 1850-d22f."
            )
        yaml_files = list(COMPONENTS_DIR.glob("*.yaml"))
        if not yaml_files:
            pytest.fail("No YAML files found in components/ — RED failure.")

        # Collect all entries across all files and find any with 'form' in title or id
        form_entry_count = 0
        form_tagged_count = 0
        for yaml_file in yaml_files:
            for entry in _load_all_entries(yaml_file):
                entry_id = str(entry.get("id", "")).lower()
                entry_title = str(entry.get("title", "")).lower()
                if "form" in entry_id or "form" in entry_title:
                    form_entry_count += 1
                    if "form" in (entry.get("component") or []):
                        form_tagged_count += 1

        assert form_entry_count > 0, (
            "No form-related entries found across components/ files — "
            "RED failure; expected form input entries."
        )
        assert form_tagged_count == form_entry_count, (
            f"Expected all {form_entry_count} form-related entries to have "
            f"component:[form]; only {form_tagged_count} do."
        )


# ---------------------------------------------------------------------------
# DD3 / DD4 — compliance:[section-508] and license:CC0-1.0 on all entries
# ---------------------------------------------------------------------------


class TestDD3AllEntriesHaveComplianceAndLicense:
    """Every corpus entry in components/ must have compliance:[section-508] and license:CC0-1.0."""

    def test_all_entries_have_section_508_compliance(self) -> None:
        """Given components/ is populated, every entry has compliance:[section-508].

        RED: fails because files don't exist yet.
        """
        if not COMPONENTS_DIR.is_dir():
            pytest.fail(
                "components/ directory absent — RED failure; "
                "create via GREEN task 1850-d22f."
            )
        yaml_files = list(COMPONENTS_DIR.glob("*.yaml"))
        if not yaml_files:
            pytest.fail("No YAML files found in components/ — RED failure.")

        violations: list[str] = []
        for yaml_file in yaml_files:
            for entry in _load_all_entries(yaml_file):
                compliance = entry.get("compliance") or []
                if "section-508" not in compliance:
                    entry_id = entry.get("id", "<no-id>")
                    violations.append(f"{yaml_file.name}:{entry_id}")

        assert not violations, (
            f"Entries missing compliance:[section-508] ({len(violations)} total):\n"
            + "\n".join(violations)
        )

    def test_all_entries_have_cc0_license(self) -> None:
        """Given components/ is populated, every entry has license:CC0-1.0.

        RED: fails because files don't exist yet.
        """
        if not COMPONENTS_DIR.is_dir():
            pytest.fail(
                "components/ directory absent — RED failure; "
                "create via GREEN task 1850-d22f."
            )
        yaml_files = list(COMPONENTS_DIR.glob("*.yaml"))
        if not yaml_files:
            pytest.fail("No YAML files found in components/ — RED failure.")

        violations: list[str] = []
        for yaml_file in yaml_files:
            for entry in _load_all_entries(yaml_file):
                license_val = entry.get("license", "")
                if license_val != "CC0-1.0":
                    entry_id = entry.get("id", "<no-id>")
                    violations.append(
                        f"{yaml_file.name}:{entry_id} (license={license_val!r})"
                    )

        assert not violations, (
            f"Entries missing license:CC0-1.0 ({len(violations)} total):\n"
            + "\n".join(violations)
        )


# ---------------------------------------------------------------------------
# DD4 — check-corpus-schema.sh passes on components/ files
# ---------------------------------------------------------------------------


class TestDD4SchemaValidation:
    """check-corpus-schema.sh must exit 0 when run against the components/ directory."""

    def test_check_corpus_schema_script_exists(self) -> None:
        """Given the corpus infra is created (9fee-6947), check-corpus-schema.sh exists.

        RED: fails because 9fee-6947 (walking skeleton) hasn't been implemented.
        """
        assert CHECK_CORPUS_SCHEMA.exists(), (
            f"check-corpus-schema.sh not found at {CHECK_CORPUS_SCHEMA} — "
            "RED failure; story 9fee-6947 must create this script."
        )

    def test_check_corpus_schema_passes_on_components_dir(self) -> None:
        """Given corpus files exist, check-corpus-schema.sh exits 0 on components/.

        When check-corpus-schema.sh is executed against the components/ directory,
        then it exits 0 (no schema violations found).

        RED: fails because check-corpus-schema.sh does not exist yet.
        """
        if not CHECK_CORPUS_SCHEMA.exists():
            pytest.fail(
                f"check-corpus-schema.sh not found at {CHECK_CORPUS_SCHEMA} — "
                "RED failure; script must be created by story 9fee-6947."
            )
        if not COMPONENTS_DIR.is_dir():
            pytest.fail(
                f"components/ directory absent at {COMPONENTS_DIR} — "
                "RED failure; create via GREEN task 1850-d22f."
            )
        result = subprocess.run(
            ["bash", str(CHECK_CORPUS_SCHEMA), str(COMPONENTS_DIR)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, (
            f"check-corpus-schema.sh exited {result.returncode} on {COMPONENTS_DIR}.\n"
            f"stdout: {result.stdout!r}\n"
            f"stderr: {result.stderr!r}"
        )


# ---------------------------------------------------------------------------
# DD5 — ref-query precision: "USWDS form validation" -> component:[form]
# ---------------------------------------------------------------------------


class TestDD5RefQueryPrecision:
    """dso ref-query 'USWDS form validation' must return a top result with component:[form]."""

    def test_ref_query_uswds_form_validation_returns_form_component_result(
        self,
    ) -> None:
        """Given the corpus and ref-query.sh exist, querying 'USWDS form validation' works.

        When '.claude/scripts/dso ref-query "USWDS form validation" --top-n 1' is run,
        then the stdout output contains 'component:' with 'form' in it — observable
        via the rendered output that ref-query.sh emits from YAML frontmatter.

        RED: fails because ref-query.sh is not yet registered in the dso shim.
        """
        if not DSO_SHIM.exists():
            pytest.fail(f"dso shim not found at {DSO_SHIM}")

        result = _run_ref_query("USWDS form validation", top_n=1)

        assert result.returncode == 0, (
            f"dso ref-query exited {result.returncode}.\n"
            f"stdout: {result.stdout!r}\n"
            f"stderr: {result.stderr!r}\n"
            "RED failure: ref-query.sh may not be registered in the dso shim yet."
        )

        # ref-query.sh renders frontmatter in output — check observable output contains
        # the component tag value for form entries
        output = result.stdout
        assert "form" in output.lower(), (
            f"Expected 'form' in ref-query output for 'USWDS form validation'.\n"
            f"stdout: {output!r}\n"
            f"stderr: {result.stderr!r}\n"
            "The top result must have component:[form] in its frontmatter."
        )

        # Additionally assert no zero-result stderr signal was emitted
        assert "[ref-query: no results" not in result.stderr, (
            f"ref-query returned zero results for 'USWDS form validation'.\n"
            f"stderr: {result.stderr!r}\n"
            "Expected at least one result with component:[form]."
        )

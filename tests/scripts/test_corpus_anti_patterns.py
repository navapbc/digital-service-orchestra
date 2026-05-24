"""Behavioral tests for the anti-patterns domain corpus entries.

Tests assert on observable file system artifacts and subprocess outputs.
All tests are expected to FAIL (RED) before the corpus files are created.

Story: f5bd-27a9 — 48 government UI/UX anti-patterns corpus
Task:  3d45-71d1-1978-447d — [RED] Write failing tests
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
ANTI_PATTERNS_DIR = (
    REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "anti-patterns"
)
CHECK_CORPUS_SCHEMA_SH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "check-corpus-schema.sh"
)
REF_QUERY_SH = REPO_ROOT / "plugins" / "dso" / "scripts" / "ref-query.sh"

VALID_DOMAINS = {"auth", "forms", "navigation", "visual"}


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------


def _yaml_files_in_dir(directory: Path) -> list[Path]:
    """Return all .yaml / .yml files in *directory* (non-recursive)."""
    if not directory.exists():
        return []
    return sorted(
        p for p in directory.iterdir() if p.suffix in {".yaml", ".yml"} and p.is_file()
    )


def _load_frontmatter(path: Path) -> dict:
    """Parse YAML frontmatter from a Markdown file.

    Frontmatter is delimited by --- on its own line.
    If the file starts with ---, parse up to the closing ---.
    Otherwise fall back to full-file YAML parse.
    """
    text = path.read_text(encoding="utf-8")
    if text.startswith("---"):
        # Strip the opening ---
        rest = text[3:]
        end_idx = rest.find("\n---")
        if end_idx != -1:
            frontmatter_text = rest[:end_idx]
            return yaml.safe_load(frontmatter_text) or {}
    # Pure YAML file (no Markdown body)
    return yaml.safe_load(text) or {}


# ---------------------------------------------------------------------------
# Test: directory existence and minimum file count
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.corpus
class TestAntiPatternsDirectoryAndCount:
    """The anti-patterns directory must exist and contain at least 48 YAML files."""

    def test_anti_patterns_directory_exists(self) -> None:
        """FAILS (RED): plugins/dso/data/ui-reference/anti-patterns/ does not exist yet."""
        assert os.path.exists(ANTI_PATTERNS_DIR), (
            f"Directory does not exist: {ANTI_PATTERNS_DIR}"
        )

    def test_anti_patterns_directory_has_at_least_48_yaml_files(self) -> None:
        """FAILS (RED): directory missing, so 0 files found instead of >=48."""
        yaml_files = _yaml_files_in_dir(ANTI_PATTERNS_DIR)
        assert len(yaml_files) >= 48, (
            f"Expected >= 48 YAML files in {ANTI_PATTERNS_DIR}, found {len(yaml_files)}"
        )


# ---------------------------------------------------------------------------
# Test: frontmatter schema — domain tag
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.corpus
class TestAntiPatternsYamlFrontmatterDomain:
    """Every entry must carry a valid domain tag from the anchored vocabulary."""

    def test_all_entries_have_domain_tag(self) -> None:
        """FAILS (RED): no files exist, so none pass the domain check."""
        yaml_files = _yaml_files_in_dir(ANTI_PATTERNS_DIR)
        assert len(yaml_files) >= 48, (
            f"Expected >= 48 YAML files — found {len(yaml_files)}. "
            "Cannot validate domain tags on empty corpus."
        )
        missing_domain = []
        for path in yaml_files:
            data = _load_frontmatter(path)
            if not data.get("domain"):
                missing_domain.append(path.name)
        assert missing_domain == [], f"Entries missing 'domain' tag: {missing_domain}"

    def test_all_domain_tags_are_valid_vocabulary(self) -> None:
        """FAILS (RED): no files exist, so the vocabulary check cannot pass."""
        yaml_files = _yaml_files_in_dir(ANTI_PATTERNS_DIR)
        assert len(yaml_files) >= 48, (
            f"Expected >= 48 YAML files — found {len(yaml_files)}. "
            "Cannot validate domain vocabulary on empty corpus."
        )
        invalid = []
        for path in yaml_files:
            data = _load_frontmatter(path)
            domains = data.get("domain", [])
            if isinstance(domains, str):
                domains = [domains]
            bad = [d for d in domains if d not in VALID_DOMAINS]
            if bad:
                invalid.append((path.name, bad))
        assert invalid == [], (
            f"Entries with invalid domain tags (must be in {VALID_DOMAINS}): {invalid}"
        )


# ---------------------------------------------------------------------------
# Test: frontmatter schema — rule_id with ap- prefix
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.corpus
class TestAntiPatternsRuleId:
    """Every entry must have a unique rule_id beginning with 'ap-'."""

    def test_all_entries_have_rule_id(self) -> None:
        """FAILS (RED): no files exist."""
        yaml_files = _yaml_files_in_dir(ANTI_PATTERNS_DIR)
        assert len(yaml_files) >= 48, (
            f"Expected >= 48 YAML files — found {len(yaml_files)}."
        )
        missing_ids = []
        for path in yaml_files:
            data = _load_frontmatter(path)
            if not data.get("rule_id"):
                missing_ids.append(path.name)
        assert missing_ids == [], f"Entries missing 'rule_id': {missing_ids}"

    def test_all_rule_ids_have_ap_prefix(self) -> None:
        """FAILS (RED): no files exist."""
        yaml_files = _yaml_files_in_dir(ANTI_PATTERNS_DIR)
        assert len(yaml_files) >= 48, (
            f"Expected >= 48 YAML files — found {len(yaml_files)}."
        )
        bad_prefix = []
        for path in yaml_files:
            data = _load_frontmatter(path)
            rule_id = data.get("rule_id", "")
            if not str(rule_id).startswith("ap-"):
                bad_prefix.append((path.name, rule_id))
        assert bad_prefix == [], (
            f"Entries whose rule_id does not start with 'ap-': {bad_prefix}"
        )

    def test_all_rule_ids_are_unique(self) -> None:
        """FAILS (RED): no files exist."""
        yaml_files = _yaml_files_in_dir(ANTI_PATTERNS_DIR)
        assert len(yaml_files) >= 48, (
            f"Expected >= 48 YAML files — found {len(yaml_files)}."
        )
        seen: dict[str, str] = {}
        duplicates = []
        for path in yaml_files:
            data = _load_frontmatter(path)
            rule_id = str(data.get("rule_id", ""))
            if rule_id in seen:
                duplicates.append((rule_id, seen[rule_id], path.name))
            else:
                seen[rule_id] = path.name
        assert duplicates == [], f"Duplicate rule_ids found: {duplicates}"


# ---------------------------------------------------------------------------
# Test: check-corpus-schema.sh passes on anti-patterns/
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.corpus
class TestCheckCorpusSchemaPasses:
    """check-corpus-schema.sh must exit 0 for the anti-patterns/ directory."""

    def test_check_corpus_schema_script_exists(self) -> None:
        """FAILS (RED): script does not exist yet."""
        assert CHECK_CORPUS_SCHEMA_SH.exists(), (
            f"check-corpus-schema.sh not found at {CHECK_CORPUS_SCHEMA_SH}"
        )

    def test_check_corpus_schema_exits_zero_for_anti_patterns(self) -> None:
        """FAILS (RED): script absent and directory absent — subprocess exits non-zero."""
        assert CHECK_CORPUS_SCHEMA_SH.exists(), (
            "check-corpus-schema.sh not found — cannot run schema validation"
        )
        result = subprocess.run(
            ["bash", str(CHECK_CORPUS_SCHEMA_SH), "anti-patterns/"],
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference"),
        )
        assert result.returncode == 0, (
            f"check-corpus-schema.sh exited {result.returncode}.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )


# ---------------------------------------------------------------------------
# Test: ref-query returns results for 'session timeout' with domain=auth
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.corpus
class TestRefQueryAntiPatterns:
    """ref-query must return >= 1 result for 'session timeout' with domain filter auth."""

    def test_ref_query_script_exists(self) -> None:
        """FAILS (RED): script does not exist yet."""
        assert REF_QUERY_SH.exists(), f"ref-query.sh not found at {REF_QUERY_SH}"

    def test_ref_query_returns_auth_result_for_session_timeout(self) -> None:
        """FAILS (RED): script absent and corpus absent — no results returned."""
        assert REF_QUERY_SH.exists(), (
            "ref-query.sh not found — cannot run retrieval check"
        )
        result = subprocess.run(
            ["bash", str(REF_QUERY_SH), "session timeout", "--domain=auth"],
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
        )
        assert result.returncode == 0, (
            f"ref-query.sh exited {result.returncode}.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
        # The script must emit at least one result line
        non_empty_lines = [ln for ln in result.stdout.splitlines() if ln.strip()]
        assert len(non_empty_lines) >= 1, (
            f"ref-query returned 0 results for 'session timeout' domain=auth.\n"
            f"stdout: {result.stdout}"
        )

"""RED tests for principles-domain design heuristics corpus entries.

These tests assert that:
1. YAML corpus files exist in plugins/dso/data/ui-reference/principles/ covering
   the six required sources (Nielsen, Norman, GOV.UK, 18F, digital.gov, Inclusive Design).
2. Each entry file has a YAML frontmatter block with domain: [principles] (or domain: principles).
3. check-corpus-schema.sh exits 0 when run against all principles/ files.
4. ref-query.sh returns at least one result for the query 'design heuristics'.

All four tests are expected to FAIL (RED phase) because:
- plugins/dso/data/ui-reference/principles/ does not yet exist
- plugins/dso/scripts/check-corpus-schema.sh does not yet exist
- plugins/dso/scripts/ref-query.sh does not yet exist

These tests will pass (GREEN phase) after Task 2 creates the corpus files
and Task 3 delivers check-corpus-schema.sh and ref-query.sh.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PRINCIPLES_DIR = REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference" / "principles"
CHECK_SCHEMA_SCRIPT = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "check-corpus-schema.sh"
)
REF_QUERY_SCRIPT = REPO_ROOT / "plugins" / "dso" / "scripts" / "ref-query.sh"

# The six required principle sources — each must have at least one corpus file
# containing the source name (case-insensitive) in the filename or in the content.
REQUIRED_SOURCES = [
    "nielsen",
    "norman",
    "govuk",
    "18f",
    "digital.gov",
    "inclusive-design",
]


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------


def _read_yaml_frontmatter(path: Path) -> dict:
    """Return parsed YAML frontmatter from a Markdown/YAML corpus file.

    Corpus files use YAML frontmatter delimited by '---' at the top.
    Falls back to treating the entire file as YAML if no delimiter found.
    Raises ValueError if the file is not parseable.
    """
    import yaml  # stdlib-bundled via PyYAML; available in this project

    content = path.read_text(encoding="utf-8")
    # Extract frontmatter between the first two '---' delimiters
    match = re.match(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL)
    if match:
        return yaml.safe_load(match.group(1)) or {}
    # Plain YAML file (no Markdown body)
    parsed = yaml.safe_load(content)
    if isinstance(parsed, dict):
        return parsed
    return {}


def _collect_principles_files() -> list[Path]:
    """Return all .yaml / .yml / .md files under the principles/ directory."""
    if not PRINCIPLES_DIR.exists():
        return []
    return [
        p
        for p in PRINCIPLES_DIR.rglob("*")
        if p.is_file()
        and p.suffix.lower() in {".yaml", ".yml", ".md"}
        and p.name != "_index.yaml"
        and p.name != "_schema.yaml"
    ]


# ---------------------------------------------------------------------------
# Test 1 — principles/ directory exists with files for all 6 required sources
# ---------------------------------------------------------------------------


def test_principles_directory_contains_all_required_sources():
    """principles/ must have at least one file per required source (six sources).

    Fails RED because plugins/dso/data/ui-reference/principles/ does not exist.
    """
    assert PRINCIPLES_DIR.exists(), (
        f"principles/ directory not found at {PRINCIPLES_DIR}. Task 2 must create it."
    )

    files = _collect_principles_files()
    assert len(files) >= 1, (
        f"No corpus files found in {PRINCIPLES_DIR}. "
        "Expected at least one YAML/Markdown entry file."
    )

    # Map each required source to whether at least one file covers it.
    # Coverage is determined by the filename or the 'source' field in frontmatter.
    missing_sources: list[str] = []
    for source_key in REQUIRED_SOURCES:
        covered = False
        for f in files:
            # Check filename
            if source_key.lower().replace(".", "").replace(
                "-", ""
            ) in f.name.lower().replace(".", "").replace("-", ""):
                covered = True
                break
            # Check frontmatter 'source' field
            try:
                fm = _read_yaml_frontmatter(f)
                file_source = str(fm.get("source", "")).lower()
                if source_key.lower().replace(".", "") in file_source.replace(".", ""):
                    covered = True
                    break
            except Exception:  # noqa: BLE001
                pass
        if not covered:
            missing_sources.append(source_key)

    assert missing_sources == [], (
        f"The following required sources have no principles/ corpus file: {missing_sources}. "
        "Task 2 must create entries for all six sources: " + ", ".join(REQUIRED_SOURCES)
    )


# ---------------------------------------------------------------------------
# Test 2 — every principles/ entry has domain: principles in YAML frontmatter
# ---------------------------------------------------------------------------


def test_all_principles_entries_have_domain_principles_tag():
    """Every corpus file in principles/ must declare domain: [principles] (or domain: principles).

    Fails RED because plugins/dso/data/ui-reference/principles/ does not exist.
    """
    assert PRINCIPLES_DIR.exists(), (
        f"principles/ directory not found at {PRINCIPLES_DIR}. Task 2 must create it."
    )

    files = _collect_principles_files()
    assert len(files) >= 1, f"No entry files found in {PRINCIPLES_DIR}."

    violations: list[str] = []
    for f in files:
        try:
            fm = _read_yaml_frontmatter(f)
        except Exception as exc:  # noqa: BLE001
            violations.append(f"{f.name}: could not parse YAML frontmatter — {exc}")
            continue

        domain = fm.get("domain", [])
        # Accept scalar 'principles' or list containing 'principles'
        if isinstance(domain, str):
            domain = [domain]
        if "principles" not in [d.strip().lower() for d in domain]:
            violations.append(
                f"{f.name}: domain={fm.get('domain')!r} does not include 'principles'"
            )

    assert violations == [], (
        "The following principles/ files are missing domain: [principles] in frontmatter:\n"
        + "\n".join(f"  - {v}" for v in violations)
    )


# ---------------------------------------------------------------------------
# Test 3 — check-corpus-schema.sh exits 0 on all principles/ files
# ---------------------------------------------------------------------------


def test_check_corpus_schema_passes_on_principles_files():
    """Running check-corpus-schema.sh against principles/ must exit 0.

    Fails RED because plugins/dso/scripts/check-corpus-schema.sh does not exist.
    """
    assert CHECK_SCHEMA_SCRIPT.exists(), (
        f"check-corpus-schema.sh not found at {CHECK_SCHEMA_SCRIPT}. "
        "Task 3 (infrastructure story) must create it."
    )
    assert PRINCIPLES_DIR.exists(), (
        f"principles/ directory not found at {PRINCIPLES_DIR}. Task 2 must create it."
    )

    result = subprocess.run(
        ["bash", str(CHECK_SCHEMA_SCRIPT), str(PRINCIPLES_DIR)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"check-corpus-schema.sh exited {result.returncode} on principles/ files.\n"
        f"stdout: {result.stdout[:500]}\n"
        f"stderr: {result.stderr[:500]}"
    )


# ---------------------------------------------------------------------------
# Test 4 — ref-query.sh returns >= 1 result for 'design heuristics'
# ---------------------------------------------------------------------------


def test_ref_query_returns_results_for_design_heuristics():
    """ref-query.sh must return at least one result for 'design heuristics'.

    Fails RED because plugins/dso/scripts/ref-query.sh does not exist.
    """
    assert REF_QUERY_SCRIPT.exists(), (
        f"ref-query.sh not found at {REF_QUERY_SCRIPT}. "
        "Task 3 (infrastructure story) must create it."
    )

    result = subprocess.run(
        ["bash", str(REF_QUERY_SCRIPT), "design heuristics"],
        capture_output=True,
        text=True,
        timeout=30,
        cwd=str(REPO_ROOT),
    )

    # ref-query.sh exits 0 even for zero results (zero-result case emits stderr signal)
    # A zero-result condition is indicated by the stderr sentinel: [ref-query: no results ...]
    zero_result_sentinel = "[ref-query: no results"
    assert zero_result_sentinel not in result.stderr, (
        f"ref-query.sh returned no results for 'design heuristics'.\n"
        f"stderr: {result.stderr[:500]}\n"
        "Task 2 must populate principles/ entries covering design heuristics content."
    )
    assert result.returncode == 0, (
        f"ref-query.sh exited {result.returncode} for query 'design heuristics'.\n"
        f"stdout: {result.stdout[:300]}\n"
        f"stderr: {result.stderr[:300]}"
    )
    assert result.stdout.strip() != "", (
        "ref-query.sh returned empty stdout for 'design heuristics'. "
        "At least one principles/ entry must match this query."
    )

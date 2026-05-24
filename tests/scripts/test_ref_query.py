"""RED tests for ref-query.py — BM25 reference query script.

These tests are RED — they assert behavior that does not exist yet.
ref-query.py has not been implemented; all tests must FAIL before
implementation.

The script is expected to expose a CLI entry point:
    python3 plugins/dso/scripts/ref-query.py <query> \\
        [--corpus <dir>] [--top-n <int>] [--tier <tier>] \\
        [--session-hash <hash>]

Observable output contract (from task AC a344-700f-b73a-456b):
  - Results are printed to stdout as newline-separated YAML or JSON records.
  - The script ranks results by BM25 relevance score (stdlib-only implementation).
  - --top-n N limits output to at most N results.
  - --tier <value> filters output to entries matching that tier field.
  - --session-hash <hash> deduplicates: identical entries from a previous session
    (identified by hash) are suppressed.
  - Zero matches: empty stdout, error message on stderr, exit code 0 or 1.

BM25 oracle discipline: all ranking assertions compare index positions
(result A appears before result B), never score equality.

Run: python3 -m pytest tests/scripts/test_ref_query.py -x
All tests must fail with ImportError or FileNotFoundError until ref-query.py
is implemented.
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import time
from pathlib import Path
from types import ModuleType

import pytest
import yaml

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "ref-query.py"
FIXTURE_CORPUS = REPO_ROOT / "tests" / "fixtures" / "ui-reference"

# ---------------------------------------------------------------------------
# Module loading helpers
# ---------------------------------------------------------------------------


def _load_module() -> ModuleType:
    """Load ref-query.py via importlib (filename contains hyphens)."""
    spec = importlib.util.spec_from_file_location("ref_query", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def ref_query_module() -> ModuleType:
    """Return the ref-query module, failing all tests if absent (RED state)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"ref-query.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Fixture corpus helpers
# ---------------------------------------------------------------------------


@pytest.fixture()
def corpus(tmp_path: Path) -> Path:
    """Copy the fixture corpus into a fresh tmp_path directory.

    Returns the path to the temporary corpus directory. Tests use only this
    temporary copy — never the live corpus.
    """
    corpus_dir = tmp_path / "corpus"
    shutil.copytree(FIXTURE_CORPUS, corpus_dir)
    return corpus_dir


def _run_ref_query(
    query: str,
    corpus_dir: Path,
    *,
    top_n: int | None = None,
    tier: str | None = None,
    session_hash: str | None = None,
    extra_args: list[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Invoke ref-query.py as a subprocess and return the CompletedProcess."""
    cmd = [
        sys.executable,
        str(SCRIPT_PATH),
        query,
        "--corpus",
        str(corpus_dir),
    ]
    if top_n is not None:
        cmd += ["--top-n", str(top_n)]
    if tier is not None:
        cmd += ["--tier", tier]
    if session_hash is not None:
        cmd += ["--session-hash", session_hash]
    if extra_args:
        cmd += extra_args
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _parse_results(stdout: str) -> list[dict]:
    """Parse newline-separated YAML documents from stdout into a list of dicts."""
    docs: list[dict] = []
    for block in stdout.strip().split("\n---"):
        block = block.strip().lstrip("-").strip()
        if not block:
            continue
        parsed = yaml.safe_load(block)
        if isinstance(parsed, dict):
            docs.append(parsed)
    return docs


# ---------------------------------------------------------------------------
# RED test 1: basic query returns ≤N results from fixture corpus
# ---------------------------------------------------------------------------


def test_basic_query_returns_results(corpus: Path) -> None:
    """GIVEN a fixture corpus with YAML entries,
    WHEN ref-query.py is invoked with a matching keyword,
    THEN stdout contains at least one result and exit code is 0.
    """
    if not SCRIPT_PATH.exists():
        pytest.fail("ref-query.py not found — RED state")

    result = _run_ref_query("button", corpus)

    assert result.returncode == 0, (
        f"Expected exit code 0 for a matching query, got {result.returncode}.\n"
        f"stderr: {result.stderr}"
    )
    assert result.stdout.strip(), (
        "Expected at least one result in stdout for query 'button', got empty output."
    )


# ---------------------------------------------------------------------------
# RED test 2: BM25 ranking-order oracle — exact keyword match ranks first
# ---------------------------------------------------------------------------


def test_bm25_ranking_exact_keyword_ranks_before_non_matching(corpus: Path) -> None:
    """GIVEN a fixture corpus where 'button.yaml' contains the word 'button'
    and 'color-palette.yaml' does not,
    WHEN ref-query.py is invoked with query 'button',
    THEN the button entry appears at a lower result index than the color entry.

    This is a ranking-order assertion, not score equality.
    """
    if not SCRIPT_PATH.exists():
        pytest.fail("ref-query.py not found — RED state")

    result = _run_ref_query("button", corpus)
    assert result.returncode == 0, f"Script failed.\nstderr: {result.stderr}"

    docs = _parse_results(result.stdout)
    assert len(docs) >= 2, (
        f"Expected at least 2 results for broad corpus query, got {len(docs)}.\n"
        f"stdout: {result.stdout}"
    )

    # Find positions of button entry and color-palette entry
    ids = [doc.get("id", "") for doc in docs]
    button_positions = [i for i, doc_id in enumerate(ids) if "button" in doc_id]
    color_positions = [i for i, doc_id in enumerate(ids) if "color" in doc_id]

    assert button_positions, f"Button entry not found in results. IDs returned: {ids}"
    assert color_positions, (
        f"Color-palette entry not found in results. IDs returned: {ids}"
    )

    button_rank = min(button_positions)
    color_rank = min(color_positions)

    assert button_rank < color_rank, (
        f"Expected button entry (rank {button_rank}) to rank before "
        f"color-palette entry (rank {color_rank}) for query 'button'. "
        f"IDs in order: {ids}"
    )


# ---------------------------------------------------------------------------
# RED test 3: --top-n limits output to exactly N results
# ---------------------------------------------------------------------------


def test_top_n_limits_results(corpus: Path) -> None:
    """GIVEN a fixture corpus with 5 entries,
    WHEN ref-query.py is invoked with --top-n 2 and a broad query,
    THEN stdout contains exactly 2 results.
    """
    if not SCRIPT_PATH.exists():
        pytest.fail("ref-query.py not found — RED state")

    # Use a broad query that should match multiple entries
    result = _run_ref_query("ui", corpus, top_n=2)

    assert result.returncode == 0, f"Script failed.\nstderr: {result.stderr}"

    docs = _parse_results(result.stdout)
    assert len(docs) == 2, (
        f"Expected exactly 2 results with --top-n 2, got {len(docs)}.\n"
        f"stdout: {result.stdout}"
    )


# ---------------------------------------------------------------------------
# RED test 4: --tier filter returns only entries matching that tier
# ---------------------------------------------------------------------------


def test_tier_filter_returns_only_matching_tier(corpus: Path) -> None:
    """GIVEN a fixture corpus with entries at tiers 'component', 'pattern', 'token',
    WHEN ref-query.py is invoked with --tier component,
    THEN all returned results have tier == 'component'.
    """
    if not SCRIPT_PATH.exists():
        pytest.fail("ref-query.py not found — RED state")

    result = _run_ref_query("ui", corpus, tier="component")

    assert result.returncode == 0, f"Script failed.\nstderr: {result.stderr}"

    docs = _parse_results(result.stdout)
    assert docs, (
        "Expected at least one result for --tier component query, got empty output."
    )

    non_component = [doc for doc in docs if doc.get("tier") != "component"]
    assert not non_component, (
        f"Expected all results to have tier='component', but got: "
        f"{[doc.get('tier') for doc in non_component]}."
    )


# ---------------------------------------------------------------------------
# RED test 5: zero-result query — empty stdout, message on stderr
# ---------------------------------------------------------------------------


def test_no_match_emits_to_stderr_and_empty_stdout(corpus: Path) -> None:
    """GIVEN a fixture corpus with no entries matching a nonsense query,
    WHEN ref-query.py is invoked with query 'xyzzy_no_such_component_ever',
    THEN stdout is empty and stderr contains a message indicating no results.
    """
    if not SCRIPT_PATH.exists():
        pytest.fail("ref-query.py not found — RED state")

    result = _run_ref_query("xyzzy_no_such_component_ever", corpus)

    assert result.stdout.strip() == "", (
        f"Expected empty stdout for no-match query, got: {result.stdout!r}"
    )
    assert result.stderr.strip(), (
        "Expected a non-empty error/info message on stderr for no-match query, "
        "but stderr was empty."
    )


# ---------------------------------------------------------------------------
# RED test 6: --session-hash deduplication removes duplicate entries
# ---------------------------------------------------------------------------


def test_session_hash_deduplication_removes_duplicates(
    corpus: Path, tmp_path: Path
) -> None:
    """GIVEN a first query that returns results with session hash 'hash-abc',
    WHEN a second identical query is run with --session-hash hash-abc,
    THEN the results are deduplicated (fewer unique entries, or empty if all
    were already seen), and no result appears twice in the combined output.

    This tests observable deduplication behavior, not internal cache structure.
    """
    if not SCRIPT_PATH.exists():
        pytest.fail("ref-query.py not found — RED state")

    session_hash = "test-session-hash-abc123"

    # First call: establish session (no prior session hash)
    first_result = _run_ref_query("button", corpus)
    assert first_result.returncode == 0, (
        f"First query failed.\nstderr: {first_result.stderr}"
    )
    first_docs = _parse_results(first_result.stdout)
    assert first_docs, "Expected results for first query"

    # Second call: same query with the session hash — expect deduplication
    second_result = _run_ref_query("button", corpus, session_hash=session_hash)
    assert second_result.returncode == 0, (
        f"Second query with session-hash failed.\nstderr: {second_result.stderr}"
    )
    second_docs = _parse_results(second_result.stdout)

    # Deduplication: the combined output must not repeat the same id twice
    all_ids = [doc.get("id") for doc in first_docs] + [
        doc.get("id") for doc in second_docs
    ]
    seen: set[str] = set()
    duplicates = []
    for doc_id in all_ids:
        if doc_id in seen:
            duplicates.append(doc_id)
        seen.add(doc_id)

    assert not duplicates, (
        f"Deduplication failed: the following IDs appeared in both the first "
        f"query results and the session-hash-deduplicated results: {duplicates}. "
        f"Session hash '{session_hash}' should have suppressed already-seen entries."
    )


# ---------------------------------------------------------------------------
# RED test 7: performance — 20-entry corpus query completes in <10 seconds
# ---------------------------------------------------------------------------


def test_performance_20_entry_corpus_under_10_seconds(tmp_path: Path) -> None:
    """GIVEN a fixture corpus expanded to 20 entries by repeating fixtures,
    WHEN ref-query.py is invoked with a standard query,
    THEN the call completes in under 10 seconds.
    """
    if not SCRIPT_PATH.exists():
        pytest.fail("ref-query.py not found — RED state")

    # Build a 20-entry corpus by repeating the 5 fixture files
    large_corpus = tmp_path / "large-corpus"
    large_corpus.mkdir()
    fixture_files = list(FIXTURE_CORPUS.glob("*.yaml"))
    assert fixture_files, f"No fixture YAML files found in {FIXTURE_CORPUS}"

    for i in range(20):
        src = fixture_files[i % len(fixture_files)]
        dest = large_corpus / f"entry-{i:02d}-{src.name}"
        # Copy and patch the id to make each entry unique
        content = yaml.safe_load(src.read_text())
        content["id"] = f"{content['id']}-copy-{i:02d}"
        dest.write_text("\n".join(f"{k}: {v!r}" for k, v in content.items()))

    start = time.monotonic()
    result = _run_ref_query("button", large_corpus, timeout=15)
    elapsed = time.monotonic() - start

    assert elapsed < 10.0, (
        f"Query against 20-entry corpus took {elapsed:.2f}s, expected <10s."
    )
    # Also verify the script actually returned without error
    assert result.returncode == 0, (
        f"Script returned non-zero exit code {result.returncode}.\n"
        f"stderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Overloaded helper to accept timeout keyword for test 7
# ---------------------------------------------------------------------------


# Patch _run_ref_query to thread through timeout for test 7 only.
# We redefine to avoid modifying the main helper signature.
def _run_ref_query(  # type: ignore[no-redef]  # noqa: F811
    query: str,
    corpus_dir: Path,
    *,
    top_n: int | None = None,
    tier: str | None = None,
    session_hash: str | None = None,
    extra_args: list[str] | None = None,
    timeout: int = 30,
) -> subprocess.CompletedProcess[str]:
    """Invoke ref-query.py as a subprocess and return the CompletedProcess."""
    cmd = [
        sys.executable,
        str(SCRIPT_PATH),
        query,
        "--corpus",
        str(corpus_dir),
    ]
    if top_n is not None:
        cmd += ["--top-n", str(top_n)]
    if tier is not None:
        cmd += ["--tier", tier]
    if session_hash is not None:
        cmd += ["--session-hash", session_hash]
    if extra_args:
        cmd += extra_args
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


# ---------------------------------------------------------------------------
# Test 8: Manifest integrity — all _index.yaml file_path entries resolve
# ---------------------------------------------------------------------------

REAL_CORPUS_DIR = REPO_ROOT / "plugins" / "dso" / "data" / "ui-reference"
REAL_INDEX_PATH = REAL_CORPUS_DIR / "_index.yaml"


@pytest.mark.unit
@pytest.mark.scripts
def test_manifest_integrity_all_index_entries_resolve() -> None:
    """GIVEN the real _index.yaml for the UI reference corpus,
    WHEN each file_path entry is resolved relative to the corpus directory,
    THEN all paths must point to existing files — no broken references.

    This is a manifest integrity test: it catches corpus files that were
    added or renamed without updating _index.yaml.
    """
    if not REAL_INDEX_PATH.exists():
        pytest.skip(f"_index.yaml not found at {REAL_INDEX_PATH}")

    with REAL_INDEX_PATH.open() as fh:
        index = yaml.safe_load(fh)

    assert isinstance(index, dict), (
        f"_index.yaml must be a YAML mapping, got {type(index).__name__}"
    )
    entries = index.get("entries", [])
    assert isinstance(entries, list), "_index.yaml 'entries' key must be a list"
    assert entries, "_index.yaml must contain at least one entry"

    missing: list[str] = []
    for entry in entries:
        assert isinstance(entry, dict), (
            f"Each entry must be a dict, got {type(entry).__name__}"
        )
        # Support both 'file_path' (new structured format) and 'path' (old format)
        rel_path = entry.get("file_path") or entry.get("path")
        assert rel_path, f"Entry missing 'file_path' or 'path' field: {entry}"
        resolved = REAL_CORPUS_DIR / rel_path
        if not resolved.exists():
            missing.append(str(rel_path))

    assert not missing, (
        "The following _index.yaml entries point to non-existent files:\n"
        + "\n".join(f"  - {p}" for p in missing)
    )

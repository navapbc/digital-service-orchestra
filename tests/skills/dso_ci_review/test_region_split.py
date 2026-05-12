"""Tests for dso_ci_review.region_split — region-split FALLBACK for large diffs.

Testing mode: RED — module does not yet exist; all tests must fail with ImportError.

Story f5f9-9a3c-c7be-4d11: Strategy E region-split FALLBACK in CI llm-review pipeline.
Ticket: 95f8-3c63-17ed-4aa7

Behavioral contracts under test:
1. _should_region_split returns True when diff has > 400 added/removed lines (LOC gate)
2. _should_region_split returns True when diff touches > 15 distinct files (file count gate)
3. _should_region_split returns False for small diffs (< 400 LOC AND < 15 files)
4. _cluster_files groups filenames by common directory prefix
5. run_region_split dispatches async_dispatch_specialists once per cluster
6. run_region_split calls dispatch_arch_synthesis exactly once (after all clusters)
7. arch synthesis result (boundary-only findings) is included in final output
"""

from __future__ import annotations

import asyncio
import sys
import pathlib

import pytest

# Ensure the plugin scripts directory is on sys.path so imports resolve correctly.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# This import MUST raise ImportError until region_split.py is implemented.
# That is the RED state.
from dso_ci_review.region_split import (  # noqa: E402
    _cluster_files,
    _should_region_split,
    run_region_split,
)


# ---------------------------------------------------------------------------
# Helpers: diff builders
# ---------------------------------------------------------------------------


def _make_diff_with_loc(added: int, removed: int, filenames: list[str] | None = None) -> str:
    """Build a synthetic unified diff with the given line counts.

    Lines starting with + (excluding +++) count as added.
    Lines starting with - (excluding ---) count as removed.
    """
    if filenames is None:
        filenames = ["src/foo.py"]

    lines: list[str] = []
    for fname in filenames:
        lines.append(f"--- a/{fname}")
        lines.append(f"+++ b/{fname}")
        lines.append("@@ -1,5 +1,5 @@")

    per_file_added = max(1, added // max(len(filenames), 1))
    per_file_removed = max(1, removed // max(len(filenames), 1))

    for _ in range(per_file_added):
        lines.append("+added line")
    for _ in range(per_file_removed):
        lines.append("-removed line")

    return "\n".join(lines)


def _make_diff_touching_files(count: int) -> str:
    """Build a synthetic diff touching `count` distinct files (1 changed line each)."""
    lines: list[str] = []
    for i in range(count):
        fname = f"src/module_{i}/file.py"
        lines.append(f"--- a/{fname}")
        lines.append(f"+++ b/{fname}")
        lines.append("@@ -1 +1 @@")
        lines.append("-old")
        lines.append("+new")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Scenario 1 — _should_region_split: LOC threshold (> 400 added/removed lines)
# ---------------------------------------------------------------------------


def test_size_gate_loc_threshold() -> None:
    """Given: a diff with > 400 added/removed lines (lines starting with +/- excluding +++/---)
    When: _should_region_split is called
    Then: returns True (LOC gate triggered)
    """
    diff = _make_diff_with_loc(added=300, removed=150)  # 450 total > 400
    result = _should_region_split(diff)
    assert result is True, (
        f"_should_region_split must return True when diff has > 400 added/removed lines; "
        f"got {result!r}"
    )


# ---------------------------------------------------------------------------
# Scenario 2 — _should_region_split: file count threshold (> 15 distinct files)
# ---------------------------------------------------------------------------


def test_size_gate_file_count_threshold() -> None:
    """Given: a diff touching > 15 distinct files
    When: _should_region_split is called
    Then: returns True (file count gate triggered)
    """
    diff = _make_diff_touching_files(16)  # 16 > 15
    result = _should_region_split(diff)
    assert result is True, (
        f"_should_region_split must return True when diff touches > 15 distinct files; "
        f"got {result!r}"
    )


# ---------------------------------------------------------------------------
# Scenario 3 — _should_region_split: small diff → False
# ---------------------------------------------------------------------------


def test_size_gate_returns_false_for_small_diff() -> None:
    """Given: a diff with < 400 lines AND < 15 files
    When: _should_region_split is called
    Then: returns False (neither gate triggered)
    """
    diff = _make_diff_with_loc(added=50, removed=50, filenames=["src/a.py", "src/b.py"])
    result = _should_region_split(diff)
    assert result is False, (
        f"_should_region_split must return False when diff has < 400 LOC AND < 15 files; "
        f"got {result!r}"
    )


# ---------------------------------------------------------------------------
# Scenario 4 — _cluster_files: groups by directory prefix
# ---------------------------------------------------------------------------


def test_cluster_files_groups_by_directory() -> None:
    """Given: a list of filenames across two directories
    When: _cluster_files is called
    Then: returns 2 clusters, each containing only filenames from that directory

    Expected shape:
        {"src/a": ["x.py", "y.py"], "src/b": ["z.py"]}
    """
    filenames = ["src/a/x.py", "src/a/y.py", "src/b/z.py"]
    clusters = _cluster_files(filenames)

    assert isinstance(clusters, dict), (
        f"_cluster_files must return a dict; got {type(clusters).__name__}"
    )
    assert len(clusters) == 2, (
        f"Expected 2 clusters (src/a, src/b); got {len(clusters)}: {list(clusters.keys())}"
    )

    # Find the cluster containing x.py / y.py
    src_a_cluster = next(
        (files for key, files in clusters.items() if "x.py" in files or "y.py" in files),
        None,
    )
    assert src_a_cluster is not None, (
        f"Expected a cluster containing x.py and y.py; clusters: {clusters}"
    )
    assert set(src_a_cluster) == {"x.py", "y.py"}, (
        f"src/a cluster must contain exactly [x.py, y.py]; got {src_a_cluster}"
    )

    # Find the cluster containing z.py
    src_b_cluster = next(
        (files for key, files in clusters.items() if "z.py" in files),
        None,
    )
    assert src_b_cluster is not None, (
        f"Expected a cluster containing z.py; clusters: {clusters}"
    )
    assert src_b_cluster == ["z.py"], (
        f"src/b cluster must contain exactly [z.py]; got {src_b_cluster}"
    )


# ---------------------------------------------------------------------------
# Scenario 5 — run_region_split: dispatches async_dispatch_specialists per cluster
# ---------------------------------------------------------------------------


def test_run_region_split_dispatches_per_cluster(monkeypatch) -> None:
    """Given: a large diff that splits into 2 clusters
    When: run_region_split is called
    Then:
      - async_dispatch_specialists is called once per cluster (2 times total)
      - dispatch_arch_synthesis is called exactly once (after all clusters)
    """
    import dso_ci_review.region_split as _region_mod

    dispatch_calls: list[list] = []
    arch_calls: list[dict] = []

    async def _mock_async_dispatch(agents: list) -> list:
        dispatch_calls.append(list(agents))
        return [{"findings": [{"severity": "minor", "description": "cluster finding", "cited_lines": []}]}]

    def _mock_arch_synthesis(merged_findings_json: str, diff_text: str, model: str, provider_chain: list) -> dict:
        arch_calls.append({"merged": merged_findings_json, "diff": diff_text})
        return {"findings": [{"severity": "important", "description": "arch boundary finding", "cited_lines": ["src/a/x.py:10"]}]}

    monkeypatch.setattr(_region_mod, "async_dispatch_specialists", _mock_async_dispatch)
    monkeypatch.setattr(_region_mod, "dispatch_arch_synthesis", _mock_arch_synthesis)

    # Patch _cluster_files to return exactly 2 clusters deterministically
    monkeypatch.setattr(_region_mod, "_cluster_files", lambda _filenames: {
        "src/a": ["x.py", "y.py"],
        "src/b": ["z.py"],
    })

    # Build a large diff (> 400 LOC) so _should_region_split would return True
    large_diff = _make_diff_with_loc(added=300, removed=150, filenames=["src/a/x.py", "src/a/y.py", "src/b/z.py"])

    tier_agents = [{"agent_id": "code-reviewer-standard", "model": "claude-sonnet-4-6", "provider_chain": ["anthropic"]}]
    provider_chain = ["anthropic"]
    config_path = None

    result = run_region_split(
        diff_text=large_diff,
        tier_agents=tier_agents,
        provider_chain=provider_chain,
        config_path=config_path,
    )

    assert len(dispatch_calls) == 2, (
        f"async_dispatch_specialists must be called once per cluster (2 clusters); "
        f"got {len(dispatch_calls)} call(s)"
    )
    assert len(arch_calls) == 1, (
        f"dispatch_arch_synthesis must be called exactly once; got {len(arch_calls)} call(s)"
    )


# ---------------------------------------------------------------------------
# Scenario 6 — run_region_split: arch synthesis findings included in result
# ---------------------------------------------------------------------------


def test_arch_synthesis_receives_merged_findings(monkeypatch) -> None:
    """Given: arch synthesis returns a boundary-only finding
    When: run_region_split completes
    Then: the returned result includes the arch synthesis finding

    The arch synthesis result (containing cross-cluster boundary findings) must
    appear in the final output — it is the whole point of the arch synthesis step.
    """
    import dso_ci_review.region_split as _region_mod

    _ARCH_FINDING = {
        "severity": "important",
        "description": "Cross-cluster boundary violation: module A depends on B internals",
        "cited_lines": ["src/a/x.py:5", "src/b/z.py:12"],
    }

    async def _mock_async_dispatch(agents: list) -> list:
        return [{"findings": [{"severity": "minor", "description": "specialist finding", "cited_lines": []}]}]

    def _mock_arch_synthesis(merged_findings_json: str, diff_text: str, model: str, provider_chain: list) -> dict:
        return {"findings": [_ARCH_FINDING]}

    monkeypatch.setattr(_region_mod, "async_dispatch_specialists", _mock_async_dispatch)
    monkeypatch.setattr(_region_mod, "dispatch_arch_synthesis", _mock_arch_synthesis)

    # 2 clusters
    monkeypatch.setattr(_region_mod, "_cluster_files", lambda _filenames: {
        "src/a": ["x.py"],
        "src/b": ["z.py"],
    })

    large_diff = _make_diff_with_loc(added=300, removed=150, filenames=["src/a/x.py", "src/b/z.py"])

    result = run_region_split(
        diff_text=large_diff,
        tier_agents=[],
        provider_chain=["anthropic"],
        config_path=None,
    )

    assert "findings" in result, (
        f"run_region_split must return a dict with 'findings' key; got keys: {list(result.keys())}"
    )
    findings = result["findings"]
    arch_findings = [f for f in findings if "boundary" in f.get("description", "").lower() or f.get("description") == _ARCH_FINDING["description"]]
    assert arch_findings, (
        f"Arch synthesis boundary finding must be present in the result. "
        f"Expected finding with description containing 'boundary'; "
        f"got findings: {findings}"
    )

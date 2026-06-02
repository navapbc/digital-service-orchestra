"""Tests for dso_ci_review.region_split — region-split FALLBACK for large diffs.

Testing mode: RED — module does not yet exist; all tests must fail with ImportError.

Story f5f9-9a3c-c7be-4d11: Strategy E region-split FALLBACK in CI llm-review pipeline.
Ticket: 95f8-3c63-17ed-4aa7

Behavioral contracts under test:
1. _should_region_split returns True when a multi-file diff has > 3000 added/removed lines
   (LOC gate; bug 532e-6ab7 raised the default from 400 → 3000 — see region_split.py docstring)
2. _should_region_split returns True when diff touches > 40 distinct files (file count gate)
3. _should_region_split returns False for small diffs (< 3000 LOC AND < 40 files)
4. _should_region_split returns False for ANY single-file diff regardless of LOC
   (file-atomicity invariant — bug 532e-6ab7)
5. _cluster_files groups filenames by common directory prefix and preserves file count
6. run_region_split dispatches async_dispatch_specialists once per cluster
7. run_region_split calls dispatch_arch_synthesis exactly once (after all clusters)
8. arch synthesis result (boundary-only findings) is included in final output
9. Thresholds are config-driven via review.region_split.{loc_threshold,file_count_threshold,max_clusters}
"""

from __future__ import annotations

import sys
import pathlib

# Ensure the plugin scripts directory is on sys.path so imports resolve correctly.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# This import MUST raise ImportError until region_split.py is implemented.
# That is the RED state.
from dso_ci_review.region_split import (  # noqa: E402
    _OVERFLOW_LABEL,
    RegionSplitInvariantError,
    _cluster_files,
    _extract_filenames,
    _should_region_split,
    run_region_split,
)
from dso_ci_review.findings import deduplicate_region_findings  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers: diff builders
# ---------------------------------------------------------------------------


def _make_diff_with_loc(
    added: int, removed: int, filenames: list[str] | None = None
) -> str:
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
# Scenario 1 — _should_region_split: LOC threshold (> 3000 added/removed lines)
# ---------------------------------------------------------------------------


def test_size_gate_loc_threshold() -> None:
    """Given: a diff above the GATE LOC threshold (default 20000) across 2+ files
    When: _should_region_split is called
    Then: returns True (GATE LOC gate triggered)

    Note (component #3'): the GATE now uses _gate_loc_threshold() (default
    20000), NOT the per-cluster fan-out _loc_threshold() (default 3000). A
    medium-large 3001-LOC diff therefore reviews single-pass — see
    test_gate_does_not_trip_below_gate_loc. The diff must also span 2+ files
    for the gate to fire (bug 532e-6ab7 single-file atomicity).
    """
    # Helper divides per-file then generates one block; ask for 30000/12000 so
    # actual produced LOC = (30000/2) + (12000/2) = 21000 > 20000 gate threshold.
    diff = _make_diff_with_loc(
        added=30000, removed=12000, filenames=["src/a.py", "src/b.py"]
    )
    result = _should_region_split(diff)
    assert result is True, (
        f"_should_region_split must return True when a multi-file diff exceeds "
        f"the GATE loc threshold (default 20000); got {result!r}"
    )


def test_gate_does_not_trip_below_gate_loc() -> None:
    """Component #3': a 3001-LOC multi-file diff (above the OLD 3000 fan-out
    threshold but below the raised 20000 GATE threshold) reviews single-pass.

    This is the core #3' behavior change: medium-large PRs no longer chunk, so
    they incur zero cross-chunk hallucinated-reference false positives.
    """
    diff = _make_diff_with_loc(
        added=4002, removed=2000, filenames=["src/a.py", "src/b.py"]
    )
    result = _should_region_split(diff)
    assert result is False, (
        f"A 3001-LOC diff must NOT trip the raised GATE (single-pass); "
        f"got {result!r}"
    )


# ---------------------------------------------------------------------------
# Scenario 1b — File-atomicity invariant: single-file diff never region-splits
# (bug 532e-6ab7)
# ---------------------------------------------------------------------------


def test_single_file_never_region_split() -> None:
    """Given: a diff touching exactly one file (even with tens of thousands of LOC)
    When: _should_region_split is called
    Then: returns False — a single source file is the atomic unit of code
    review and must never be region-split, regardless of LOC count.
    """
    diff = _make_diff_with_loc(added=20000, removed=20000, filenames=["src/huge.py"])
    result = _should_region_split(diff)
    assert result is False, (
        f"_should_region_split must return False for any single-file diff "
        f"(bug 532e-6ab7 file-atomicity invariant); got {result!r}"
    )


def test_cluster_files_atomicity_count_preserved() -> None:
    """Given: an input filename list
    When: _cluster_files is called
    Then: the total number of entries across all returned cluster lists equals
    the input filename count — every file appears in exactly one cluster
    (bug 532e-6ab7 file-atomicity invariant, count-preservation form).
    """
    filenames = ["a/x.py", "a/y.py", "b/z.py", "c/w.py", "top.py"]
    clusters = _cluster_files(filenames)
    total = sum(len(v) for v in clusters.values())
    assert total == len(filenames), (
        f"File-atomicity: total cluster entries ({total}) must equal input "
        f"count ({len(filenames)}); clusters={clusters}"
    )


def test_loc_threshold_config_override(tmp_path, monkeypatch) -> None:
    """Given: a config file lowering the GATE threshold review.region_split.gate_loc to 100
    When: a 200-LOC two-file diff is checked
    Then: _should_region_split returns True (config-overridden GATE threshold fires).

    Component #3': the GATE reads review.region_split.gate_loc (not the
    per-cluster fan-out review.region_split.loc_threshold). Verifies config
    indirection: the gate threshold is not a hardcoded constant.
    """
    # Build a config file with a low GATE threshold
    config_dir = tmp_path / ".claude"
    config_dir.mkdir()
    # gate_loc must stay above the 300 size_upgrade_lines floor (else it is
    # clamped up); 350 is a valid low override that still proves config indirection.
    config_file = config_dir / "dso-config.conf"
    config_file.write_text("review.region_split.gate_loc=350\n")

    # Make _default_config_path resolve to our temp config
    from dso_ci_review import region_split as rs

    # Patch the shared config resolver where it lives — region_split's
    # threshold readers ultimately delegate to dso_ci_review._config.read_config_int
    # which calls default_config_path() when no path is passed.
    from dso_ci_review import _config as cfg_mod

    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))

    # 400-LOC two-file diff — under the 20000 default, but over the 350 override
    diff = _make_diff_with_loc(
        added=400, removed=400, filenames=["src/a.py", "src/b.py"]
    )
    # Helper: (400/2)+(400/2) = 400 LOC produced
    result = rs._should_region_split(diff)
    assert result is True, (
        f"Config override should make the GATE fire at gate_loc=350 (vs 20000 default); "
        f"got {result!r}"
    )

    # And the inverse: without the override (empty config), 400 LOC < 20000 default → False
    empty_config = tmp_path / "empty.conf"
    empty_config.write_text("")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(empty_config))
    result_default = rs._should_region_split(diff)
    assert result_default is False, (
        f"With default GATE threshold (20000), 400-LOC diff should not region-split; "
        f"got {result_default!r}"
    )


def test_threshold_readers_clamp_invalid_config_to_default(
    tmp_path, monkeypatch
) -> None:
    """Zero/negative threshold values from config must fall back to defaults.

    PR #169 review (coderabbit f-positive-integer): _read_config_int returns
    whatever integer the config holds, so a misconfigured 0 / -1 would
    disable gating or invert comparisons. Threshold readers must clamp.
    """
    from dso_ci_review import region_split as rs

    # Config with all three thresholds set to invalid values
    config_file = tmp_path / "bad-config.conf"
    config_file.write_text(
        "review.region_split.loc_threshold=0\n"
        "review.region_split.max_clusters=0\n"
    )
    # Patch the shared config resolver where it lives — region_split's
    # threshold readers ultimately delegate to dso_ci_review._config.read_config_int
    # which calls default_config_path() when no path is passed.
    from dso_ci_review import _config as cfg_mod

    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))

    assert rs._loc_threshold() == rs._LOC_THRESHOLD_DEFAULT, (
        "loc_threshold must fall back to default when config value is 0"
    )
    assert rs._max_clusters() == rs._MAX_CLUSTERS_DEFAULT, (
        "max_clusters must fall back to default when config value is < 1"
    )


def test_cluster_files_overflow_preserves_full_paths() -> None:
    """When the overflow cluster is created, its entries must be FULL PATHS.

    PR #169 review (coderabbit f-overflow-identity): overflow previously
    stored only basenames, so the downstream _extract_cluster_diff would
    build nonexistent ``overflow/<basename>`` paths and silently dispatch
    the whole diff. Each overflow entry must include its original parent
    directory so _extract_cluster_diff resolves to the real hunks.
    """
    # 6 single-file directories — exceeds _MAX_CLUSTERS_DEFAULT (5), forcing
    # overflow. The smallest clusters (all size-1) are merged.
    filenames = [
        "alpha/a.py",
        "beta/b.py",
        "gamma/c.py",
        "delta/d.py",
        "epsilon/e.py",
        "zeta/f.py",
    ]
    clusters = _cluster_files(filenames)
    assert _OVERFLOW_LABEL in clusters, (
        f"Expected an overflow cluster with 6 input dirs > 5 cap; got {list(clusters.keys())}"
    )
    overflow = clusters[_OVERFLOW_LABEL]
    # Every overflow entry must contain '/' (be a full path), not a bare basename
    bare = [f for f in overflow if "/" not in f]
    assert not bare, (
        f"Overflow entries must be full paths preserving parent directory; "
        f"found bare basenames: {bare}"
    )
    # Verify the parent directories are among the inputs
    overflow_dirs = {f.rsplit("/", 1)[0] for f in overflow}
    input_dirs = {f.rsplit("/", 1)[0] for f in filenames}
    assert overflow_dirs.issubset(input_dirs), (
        f"Overflow parent dirs {overflow_dirs} must be from the input set {input_dirs}"
    )


def test_extract_cluster_diff_resolves_overflow_paths() -> None:
    """_extract_cluster_diff must find hunks for files in the overflow cluster.

    PR #169 review (coderabbit f-overflow-identity): with overflow now
    storing full paths, _extract_cluster_diff must treat overflow like the
    "." pseudo-cluster — use the entries as full paths verbatim rather
    than prepending "overflow/" to them.
    """
    # Reach into the private extractor; this is structural plumbing not
    # exposed as a public API.
    from dso_ci_review.region_split import _extract_cluster_diff  # noqa: PLC0415

    diff_text = (
        "diff --git a/zeta/f.py b/zeta/f.py\n"
        "--- a/zeta/f.py\n"
        "+++ b/zeta/f.py\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
        "diff --git a/other/x.py b/other/x.py\n"
        "--- a/other/x.py\n"
        "+++ b/other/x.py\n"
        "@@ -1 +1 @@\n"
        "-old2\n"
        "+new2\n"
    )
    # Overflow cluster (full paths) should select only the zeta hunk
    result = _extract_cluster_diff(diff_text, _OVERFLOW_LABEL, ["zeta/f.py"])
    assert "zeta/f.py" in result, (
        f"Overflow extraction must include the zeta/f.py hunk; got: {result!r}"
    )
    assert "other/x.py" not in result, (
        "Overflow extraction must NOT include hunks for non-overflow files; "
        "leaked: other/x.py present in result"
    )


def test_cluster_files_atomicity_holds_under_overflow() -> None:
    """Given: more directories than _MAX_CLUSTERS (forces overflow)
    When: _cluster_files is called
    Then: total file count is still preserved across all clusters (including
    overflow). Overflow must neither drop nor duplicate files.
    """
    filenames = [f"dir{i}/file.py" for i in range(10)]  # 10 dirs > _MAX_CLUSTERS=5
    clusters = _cluster_files(filenames)
    total = sum(len(v) for v in clusters.values())
    assert total == len(filenames), (
        f"File-atomicity under overflow: input count {len(filenames)} vs "
        f"cluster total {total}; clusters={clusters}"
    )
    assert _OVERFLOW_LABEL in clusters, (
        f"Expected {_OVERFLOW_LABEL!r} cluster when input exceeds _MAX_CLUSTERS; "
        f"got {list(clusters.keys())}"
    )


# ---------------------------------------------------------------------------
# Scenario 2 — _should_region_split: file count threshold (> 40 distinct files)
# ---------------------------------------------------------------------------


def test_size_gate_file_count_threshold() -> None:
    """Given: a diff touching > the GATE file-count threshold (default 120)
    When: _should_region_split is called
    Then: returns True (GATE file-count gate triggered)

    Component #3': the GATE now uses _gate_file_count_threshold() (default
    120), NOT the per-cluster fan-out _file_count_threshold() (default 40). A
    41-file diff therefore reviews single-pass — see
    test_gate_does_not_trip_below_gate_file_count.
    """
    diff = _make_diff_touching_files(121)  # 121 > 120
    result = _should_region_split(diff)
    assert result is True, (
        f"_should_region_split must return True when diff touches > the GATE "
        f"file-count threshold (default 120); got {result!r}"
    )


def test_gate_does_not_trip_below_gate_file_count() -> None:
    """Component #3': a 41-file diff (above the OLD 40 fan-out file threshold
    but below the raised 120 GATE threshold) reviews single-pass.
    """
    diff = _make_diff_touching_files(41)  # 41 > 40 (old) but < 120 (gate)
    result = _should_region_split(diff)
    assert result is False, (
        f"A 41-file diff must NOT trip the raised GATE (single-pass); "
        f"got {result!r}"
    )


# ---------------------------------------------------------------------------
# Scenario 3 — _should_region_split: small diff → False
# ---------------------------------------------------------------------------


def test_size_gate_returns_false_for_small_diff() -> None:
    """Given: a diff with < 3000 lines AND < 40 files
    When: _should_region_split is called
    Then: returns False (neither gate triggered)
    """
    diff = _make_diff_with_loc(added=50, removed=50, filenames=["src/a.py", "src/b.py"])
    result = _should_region_split(diff)
    assert result is False, (
        f"_should_region_split must return False when diff has < 3000 LOC AND < 40 files; "
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
        (
            files
            for key, files in clusters.items()
            if "x.py" in files or "y.py" in files
        ),
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
    _region_mod = sys.modules[run_region_split.__module__]

    dispatch_calls: list[list] = []
    arch_calls: list[dict] = []

    async def _mock_async_dispatch(agents: list) -> list:
        dispatch_calls.append(list(agents))
        return [
            {
                "findings": [
                    {
                        "severity": "minor",
                        "description": "cluster finding",
                        "cited_lines": [],
                    }
                ]
            }
        ]

    def _mock_arch_synthesis(
        merged_findings_json: str, diff_text: str, model: str, provider_chain: list
    ) -> dict:
        arch_calls.append({"merged": merged_findings_json, "diff": diff_text})
        return {
            "findings": [
                {
                    "severity": "important",
                    "description": "arch boundary finding",
                    "cited_lines": ["src/a/x.py:10"],
                }
            ]
        }

    monkeypatch.setattr(_region_mod, "async_dispatch_specialists", _mock_async_dispatch)
    monkeypatch.setattr(_region_mod, "dispatch_arch_synthesis", _mock_arch_synthesis)

    # Patch _cluster_files to return exactly 2 clusters deterministically
    monkeypatch.setattr(
        _region_mod,
        "_cluster_files",
        lambda _filenames: {
            "src/a": ["x.py", "y.py"],
            "src/b": ["z.py"],
        },
    )

    # Diff size doesn't matter here — _cluster_files is mocked above and
    # run_region_split is invoked directly, bypassing the _should_region_split gate.
    large_diff = _make_diff_with_loc(
        added=300, removed=150, filenames=["src/a/x.py", "src/a/y.py", "src/b/z.py"]
    )

    tier_agents = [
        {
            "agent_id": "code-reviewer-standard",
            "model": "claude-sonnet-4-6",
            "provider_chain": ["anthropic"],
        }
    ]
    provider_chain = ["anthropic"]
    config_path = None

    run_region_split(
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
    _region_mod = sys.modules[run_region_split.__module__]

    _ARCH_FINDING = {
        "severity": "important",
        "description": "Cross-cluster boundary violation: module A depends on B internals",
        "cited_lines": ["src/a/x.py:5", "src/b/z.py:12"],
    }

    async def _mock_async_dispatch(agents: list) -> list:
        return [
            {
                "findings": [
                    {
                        "severity": "minor",
                        "description": "specialist finding",
                        "cited_lines": [],
                    }
                ]
            }
        ]

    def _mock_arch_synthesis(
        merged_findings_json: str, diff_text: str, model: str, provider_chain: list
    ) -> dict:
        return {"findings": [_ARCH_FINDING]}

    monkeypatch.setattr(_region_mod, "async_dispatch_specialists", _mock_async_dispatch)
    monkeypatch.setattr(_region_mod, "dispatch_arch_synthesis", _mock_arch_synthesis)

    # 2 clusters
    monkeypatch.setattr(
        _region_mod,
        "_cluster_files",
        lambda _filenames: {
            "src/a": ["x.py"],
            "src/b": ["z.py"],
        },
    )

    large_diff = _make_diff_with_loc(
        added=300, removed=150, filenames=["src/a/x.py", "src/b/z.py"]
    )

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
    arch_findings = [
        f
        for f in findings
        if "boundary" in f.get("description", "").lower()
        or f.get("description") == _ARCH_FINDING["description"]
    ]
    assert arch_findings, (
        f"Arch synthesis boundary finding must be present in the result. "
        f"Expected finding with description containing 'boundary'; "
        f"got findings: {findings}"
    )


# ---------------------------------------------------------------------------
# Scenario 6b — run_region_split: prior_defenses forwarded to arch synthesis
# ---------------------------------------------------------------------------


def test_run_region_split_forwards_prior_defenses_to_arch_synthesis(
    monkeypatch,
) -> None:
    """Given: prior_defenses are provided to run_region_split (cycle N≥2 re-review)
    When: run_region_split calls dispatch_arch_synthesis
    Then: the merged_findings_json passed to arch synthesis includes the defense context
          so the arch synthesizer avoids re-emitting defended findings.
    """
    _region_mod = sys.modules[run_region_split.__module__]

    _DEFENSE = {
        "severity": "important",
        "description": "Some prior finding",
        "defense_text": "This is a false positive because X.",
    }
    captured_args: list[dict] = []

    async def _mock_async_dispatch(agents: list) -> list:
        return [{"findings": []}]

    def _mock_arch_synthesis(
        merged_findings_json: str, diff_text: str, model: str, provider_chain: list
    ) -> dict:
        captured_args.append({"merged_findings_json": merged_findings_json})
        return {"findings": []}

    monkeypatch.setattr(_region_mod, "async_dispatch_specialists", _mock_async_dispatch)
    monkeypatch.setattr(_region_mod, "dispatch_arch_synthesis", _mock_arch_synthesis)
    monkeypatch.setattr(
        _region_mod,
        "_cluster_files",
        lambda _filenames: {"src": ["foo.py"]},
    )

    large_diff = _make_diff_with_loc(added=300, removed=150, filenames=["src/foo.py"])

    run_region_split(
        diff_text=large_diff,
        tier_agents=[],
        provider_chain=["anthropic"],
        config_path=None,
        prior_defenses=[_DEFENSE],
    )

    assert captured_args, "dispatch_arch_synthesis must have been called"
    passed_json = captured_args[0]["merged_findings_json"]
    assert "Prior round defenses" in passed_json, (
        "merged_findings_json passed to arch synthesis must include the defense context "
        f"when prior_defenses is non-empty; got: {passed_json[:200]}"
    )
    assert _DEFENSE["defense_text"] in passed_json, (
        "Defense text must appear in the merged_findings_json passed to arch synthesis"
    )


# ---------------------------------------------------------------------------
# Scenario 7 (SC5) — deduplicate_region_findings: overlapping regions, MAX-severity
#                     wins, dual-rationale preserved
# ---------------------------------------------------------------------------


def test_overlapping_region_max_severity_and_dual_rationale_dedup() -> None:
    """Given: two findings in the same file with overlapping line ranges and different severities
    When: deduplicate_region_findings is called (the dedup contract used by the region-split path)
    Then:
      - Exactly one finding emerges (overlap triggers dedup)
      - The emerged finding has the MAX (Critical) severity
      - merged_rationale is populated and contains both original rationale substrings
        (dual-rationale preservation)

    This exercises the dedup contract that parallel cluster specialists produce
    overlapping findings when their assigned diff regions share a hunk boundary.
    """
    finding_critical = {
        "file_path": "src/auth/login.py",
        "dimension": "correctness",
        "severity": "critical",
        "description": "Missing authentication check allows unauthenticated access",
        "rationale": "No auth guard on the endpoint allows any caller to bypass login",
        "cited_lines": ["src/auth/login.py:10-30"],
    }
    finding_important = {
        "file_path": "src/auth/login.py",
        "dimension": "correctness",
        "severity": "important",
        "description": "Session token not invalidated on logout",
        "rationale": "Token remains valid after logout creating a session fixation risk",
        "cited_lines": [
            "src/auth/login.py:20-45"
        ],  # overlaps lines 20-30 with the first finding
    }

    result = deduplicate_region_findings([finding_critical, finding_important])

    assert len(result) == 1, (
        f"Overlapping findings in the same (file_path, dimension) bucket must dedup to exactly "
        f"one finding; got {len(result)}: {result}"
    )

    merged = result[0]

    assert merged["severity"] == "critical", (
        f"MAX severity must win: expected 'critical', got {merged['severity']!r}. "
        f"Merged finding: {merged}"
    )

    mr = merged.get("merged_rationale")
    assert mr is not None, (
        f"merged_rationale must be present when two findings with different severities are merged; "
        f"merged finding: {merged}"
    )
    assert isinstance(mr, dict), (
        f"merged_rationale must be a dict with 'primary' and 'secondary' keys; got {type(mr).__name__}"
    )

    primary_text = mr.get("primary", "")
    secondary_text = mr.get("secondary", "")

    assert (
        finding_critical["rationale"] in primary_text
        or finding_critical["rationale"] in secondary_text
    ), (
        f"merged_rationale must preserve the Critical finding's rationale text; "
        f"expected substring {finding_critical['rationale']!r} in merged_rationale; "
        f"got primary={primary_text!r}, secondary={secondary_text!r}"
    )
    assert (
        finding_important["rationale"] in primary_text
        or finding_important["rationale"] in secondary_text
    ), (
        f"merged_rationale must preserve the Important finding's rationale text; "
        f"expected substring {finding_important['rationale']!r} in merged_rationale; "
        f"got primary={primary_text!r}, secondary={secondary_text!r}"
    )


# ---------------------------------------------------------------------------
# Scenario 8 — deduplicate_region_findings: edge cases
# ---------------------------------------------------------------------------


def test_dedup_does_not_merge_non_overlapping_same_file() -> None:
    """Given: two findings in the same file with NON-overlapping line ranges
    When: deduplicate_region_findings is called
    Then: both findings are returned unchanged (no dedup across non-overlapping ranges)
    """
    finding_a = {
        "file_path": "src/auth/login.py",
        "dimension": "correctness",
        "severity": "important",
        "description": "Finding A",
        "rationale": "Rationale A",
        "cited_lines": ["src/auth/login.py:1-10"],
    }
    finding_b = {
        "file_path": "src/auth/login.py",
        "dimension": "correctness",
        "severity": "important",
        "description": "Finding B",
        "rationale": "Rationale B",
        "cited_lines": ["src/auth/login.py:50-60"],  # no overlap with 1-10
    }

    result = deduplicate_region_findings([finding_a, finding_b])

    assert len(result) == 2, (
        f"Non-overlapping findings in the same file must NOT be deduped; got {len(result)}: {result}"
    )


def test_dedup_does_not_merge_different_files() -> None:
    """Given: two findings with the SAME line range but different file_path values
    When: deduplicate_region_findings is called
    Then: both findings are returned unchanged (file_path boundary is respected)
    """
    finding_a = {
        "file_path": "src/auth/login.py",
        "dimension": "correctness",
        "severity": "important",
        "description": "Finding in login.py",
        "rationale": "Rationale in login",
        "cited_lines": ["src/auth/login.py:10-30"],
    }
    finding_b = {
        "file_path": "src/auth/logout.py",
        "dimension": "correctness",
        "severity": "important",
        "description": "Finding in logout.py",
        "rationale": "Rationale in logout",
        "cited_lines": ["src/auth/logout.py:10-30"],  # same range, different file
    }

    result = deduplicate_region_findings([finding_a, finding_b])

    assert len(result) == 2, (
        f"Findings in different files must NOT be deduped even if line ranges match; "
        f"got {len(result)}: {result}"
    )


def test_dedup_single_element_passes_through() -> None:
    """Given: a single finding
    When: deduplicate_region_findings is called
    Then: exactly one finding is returned unchanged
    """
    finding = {
        "file_path": "src/auth/login.py",
        "dimension": "correctness",
        "severity": "critical",
        "description": "Solo finding",
        "rationale": "Solo rationale",
        "cited_lines": ["src/auth/login.py:5-15"],
    }

    result = deduplicate_region_findings([finding])

    assert len(result) == 1, (
        f"Single-element input must pass through unchanged; got {len(result)}: {result}"
    )
    assert result[0]["description"] == finding["description"], (
        f"Single finding must be returned unmodified; got {result[0]}"
    )


def test_dedup_empty_list_returns_empty() -> None:
    """Given: an empty list
    When: deduplicate_region_findings is called
    Then: an empty list is returned
    """
    result = deduplicate_region_findings([])

    assert result == [], f"Empty input must return empty list; got {result!r}"


# ---------------------------------------------------------------------------
# PR #169 cycle-2 review findings — additional coverage
# ---------------------------------------------------------------------------


def test_atomicity_check_catches_drop_plus_duplicate() -> None:
    """Identity-based atomicity (coderabbit f-counter-not-count): a cluster
    state that DROPS one file and DUPLICATES another preserves total count
    but corrupts identity. The strengthened _assert_file_atomicity must
    catch this and raise RegionSplitInvariantError, not pass silently.
    """
    from dso_ci_review.region_split import _assert_file_atomicity  # noqa: PLC0415

    inputs = ["a/x.py", "b/y.py", "c/z.py"]
    # Corrupt cluster output: "b/y.py" missing, "a/x.py" duplicated.
    # Total count == 3 (matches input count) but identities diverge.
    corrupt_clusters = {"a": ["x.py", "x.py"], "c": ["z.py"]}

    raised = None
    try:
        _assert_file_atomicity(inputs, corrupt_clusters)
    except RegionSplitInvariantError as exc:
        raised = exc

    assert raised is not None, (
        "Count-only atomicity check would miss a drop+duplicate; the new "
        "identity-based check (Counter comparison) must raise"
    )
    msg = str(raised)
    assert "b/y.py" in msg, (
        f"Error message must name the dropped file (b/y.py); got: {msg!r}"
    )
    assert "missing" in msg or "extra" in msg, (
        f"Error message must distinguish missing vs extra identities; got: {msg!r}"
    )


def test_atomicity_check_uses_domain_exception_not_assertion_error() -> None:
    """The atomicity check must raise RegionSplitInvariantError (not
    AssertionError) so callers can catch a domain-specific failure and so
    the message survives ``python -O`` (PR #169 f-assertion-error-style).
    """
    from dso_ci_review.region_split import _assert_file_atomicity  # noqa: PLC0415

    raised: BaseException | None = None
    try:
        _assert_file_atomicity(["a.py"], {})  # input has 1 file, clusters has 0
    except BaseException as exc:  # noqa: BLE001 — we want to see exact type
        raised = exc

    assert raised is not None, "atomicity check must raise on identity mismatch"
    assert isinstance(raised, RegionSplitInvariantError), (
        f"Expected RegionSplitInvariantError, got {type(raised).__name__}: {raised!r}"
    )
    # And AssertionError is reserved for `assert` statements — must NOT be used here
    assert not isinstance(raised, AssertionError), (
        "Production code should raise a domain-specific exception rather than "
        "AssertionError (which some tooling rewrites or swallows)"
    )


def test_extract_filenames_includes_deletions() -> None:
    """Pure-deletion diffs have ``+++ /dev/null`` (not a real path) but
    DO have a ``diff --git a/X b/X`` header. The unified extractor must
    capture them via the diff-git header so the gate and the clustering
    path agree on the file set (PR #169 f-gate-vs-clustering-divergence).
    """
    diff_text = (
        "diff --git a/deleted.py b/deleted.py\n"
        "deleted file mode 100644\n"
        "--- a/deleted.py\n"
        "+++ /dev/null\n"
        "@@ -1,2 +0,0 @@\n"
        "-old1\n"
        "-old2\n"
        "diff --git a/kept.py b/kept.py\n"
        "--- a/kept.py\n"
        "+++ b/kept.py\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    )
    files = _extract_filenames(diff_text)
    assert "deleted.py" in files, (
        f"Deletion (+++ /dev/null) must still be extracted via diff --git header; "
        f"got: {files}"
    )
    assert "kept.py" in files, f"Modified file must be extracted; got: {files}"


def test_gate_and_clustering_see_same_file_set_under_deletion() -> None:
    """End-to-end version of f-gate-vs-clustering-divergence: with a
    multi-file diff that includes a deletion, both _should_region_split's
    gate and _async_run_region_split's clustering path (via _cluster_files)
    must see the same file count.
    """
    # 121 files (clears the raised 120-file GATE threshold under #3'), one of
    # which is a deletion.
    diff_lines: list[str] = []
    diff_lines.extend(
        [
            "diff --git a/d/deleted.py b/d/deleted.py",
            "deleted file mode 100644",
            "--- a/d/deleted.py",
            "+++ /dev/null",
            "@@ -1 +0,0 @@",
            "-old",
        ]
    )
    for i in range(120):
        diff_lines.extend(
            [
                f"diff --git a/m/file_{i}.py b/m/file_{i}.py",
                f"--- a/m/file_{i}.py",
                f"+++ b/m/file_{i}.py",
                "@@ -1 +1 @@",
                "-old",
                "+new",
            ]
        )
    diff_text = "\n".join(diff_lines)

    # Gate sees the deletion: file_count = 121 > 120 (gate) → should region-split
    assert _should_region_split(diff_text) is True, (
        "Gate must trigger region-split when total files including deletions "
        "exceeds the GATE file-count threshold (120)"
    )

    # Clustering must see the SAME file set — including the deletion — so the
    # atomicity invariant has a faithful baseline. _cluster_files will raise
    # RegionSplitInvariantError if a file is dropped.
    files = _extract_filenames(diff_text)
    assert len(files) == 121, (
        f"Unified extractor must see all 121 files (including the deletion); "
        f"got {len(files)}: {files}"
    )
    # Atomicity assertion fires inside _cluster_files; if it raised, the test
    # would error out here, which is exactly the regression contract.
    clusters = _cluster_files(files)
    assert sum(len(v) for v in clusters.values()) == 121, (
        f"Clustering must preserve all 121 files; got clusters={clusters}"
    )


def test_overflow_sentinel_does_not_collide_with_real_directory() -> None:
    """If a diff legitimately touches files under a directory literally
    named ``overflow/`` and the cluster cap forces overflow merging, the
    synthesized cluster label (``__overflow__``) must NOT overwrite the
    real cluster (PR #169 f-overflow-sentinel-collision).
    """
    # 6 directories including a real "overflow/" — exceeds _MAX_CLUSTERS=5
    filenames = [
        "overflow/real.py",  # real directory called "overflow"
        "alpha/a.py",
        "beta/b.py",
        "gamma/c.py",
        "delta/d.py",
        "epsilon/e.py",
    ]
    clusters = _cluster_files(filenames)
    # Both labels can coexist when both are populated
    assert "overflow" in clusters or _OVERFLOW_LABEL in clusters, (
        f"At least one of the real 'overflow' dir or the sentinel "
        f"{_OVERFLOW_LABEL!r} must be present; got {list(clusters.keys())}"
    )
    # File-atomicity check (now identity-based) verifies no file was lost
    # to a label collision — if the sentinel had overwritten the real
    # 'overflow' cluster, _assert_file_atomicity would have raised before
    # _cluster_files returned.
    all_paths: list[str] = []
    for label, entries in clusters.items():
        if label in {".", _OVERFLOW_LABEL}:
            all_paths.extend(entries)
        else:
            all_paths.extend(f"{label}/{e}" for e in entries)
    assert "overflow/real.py" in all_paths, (
        f"Real 'overflow/real.py' must be reachable across clusters; got: {all_paths}"
    )

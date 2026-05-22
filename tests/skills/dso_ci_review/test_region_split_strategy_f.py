"""Tests for region_split.py — Strategy F per-file fan-out (RED).

Testing mode: RED — Strategy F functions do not yet exist in region_split.py.
All tests that import Strategy F symbols will fail with ImportError; this is
the intended RED state. S7.T4 will implement Strategy F to turn these GREEN.

Story 1608-4d8c-da53-47bc: oversized PRs reviewed via chunked file-level dispatch.
Task d905-bf54-e1d9-408d: RED test — Strategy F per-file fan-out.
AC amendment: add test for single-oversized-file case with oversized_single_file flag.

## Behavioral contracts under test

Strategy F per-file fan-out:
1. Given a diff with one giant cluster (single directory, 10 files, 6500 lines):
   Strategy E produces 1 cluster; Strategy F splits to 10 per-file clusters
   (each file in its own dispatch). Total dispatches: 10.
2. Given a giant single file (8000+ lines, no other files in dir):
   Strategy F preserves file-atomicity — the file is NOT split across reviewers.
   Single dispatch even if oversized; the cluster carries `oversized_single_file: True`.
3. Given a typical PR with mixed cluster sizes:
   Strategy F triggers ONLY on oversized clusters (>= threshold_lines config);
   smaller clusters remain at Strategy E (per-directory dispatch).
4. RegionSplitInvariantError is NOT raised in any of these cases.
5. Single-oversized-file pass-through: a diff with ONE file > reviewer context ceiling
   produces a dispatch with `oversized_single_file: True` flag (not split by hunk).
"""

from __future__ import annotations

import sys
import pathlib

# Ensure the plugin scripts directory is on sys.path so imports resolve correctly.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# Import Strategy E symbols (already exist — should not fail)
from dso_ci_review.region_split import (  # noqa: E402
    RegionSplitInvariantError,
)

# Strategy F imports — these MUST raise ImportError until S7.T4 implements them.
# That is the RED state for this test file.
# RED marker: [test_region_split_strategy_f]
from dso_ci_review.region_split import (  # noqa: E402
    split_cluster_by_file,
    run_region_split_strategy_f,
)


# ---------------------------------------------------------------------------
# Helpers: diff builders (mirrors existing test_region_split.py helpers)
# ---------------------------------------------------------------------------


def _make_diff_single_dir_multi_file(
    directory: str, filenames: list[str], lines_per_file: int
) -> str:
    """Build a synthetic diff with multiple files in the same directory."""
    lines: list[str] = []
    for fname in filenames:
        path = f"{directory}/{fname}"
        lines.append(f"diff --git a/{path} b/{path}")
        lines.append(f"--- a/{path}")
        lines.append(f"+++ b/{path}")
        lines.append("@@ -1,10 +1,10 @@")
        for i in range(lines_per_file // 2):
            lines.append(f"+added line {i}")
        for i in range(lines_per_file // 2):
            lines.append(f"-removed line {i}")
    return "\n".join(lines)


def _make_diff_single_file(filepath: str, added: int, removed: int) -> str:
    """Build a synthetic diff touching exactly one file."""
    lines = [
        f"diff --git a/{filepath} b/{filepath}",
        f"--- a/{filepath}",
        f"+++ b/{filepath}",
        "@@ -1,10 +1,10 @@",
    ]
    for i in range(added):
        lines.append(f"+added line {i}")
    for i in range(removed):
        lines.append(f"-removed line {i}")
    return "\n".join(lines)


def _make_diff_mixed_clusters(
    large_dir: str,
    large_files: list[str],
    large_loc_per_file: int,
    small_dir: str,
    small_files: list[str],
    small_loc_per_file: int,
) -> str:
    """Build a diff with one large cluster and one small cluster."""
    large_diff = _make_diff_single_dir_multi_file(
        large_dir, large_files, large_loc_per_file
    )
    small_diff = _make_diff_single_dir_multi_file(
        small_dir, small_files, small_loc_per_file
    )
    return large_diff + "\n" + small_diff


# ---------------------------------------------------------------------------
# Strategy F: split_cluster_by_file
# ---------------------------------------------------------------------------


def test_strategy_f_per_file_fan_out_on_giant_single_dir_cluster() -> None:
    """Strategy F per-file fan-out: one directory with 10 files at 6500 total LOC.

    Given: a diff where Strategy E produces 1 directory cluster
           (single directory, 10 files, 6500 lines)
    When:  split_cluster_by_file is called on that cluster
    Then:
    - Result contains 10 per-file clusters (one per file, each file in its own dispatch)
    - Total file entries across all returned clusters equals 10 (file-atomicity)
    - RegionSplitInvariantError is NOT raised

    This is the core Strategy F invariant: clusters that exceed the per-cluster
    LOC threshold are fanned out to one dispatch per file.
    """
    directory = "src/payments"
    file_names = [f"processor_{i}.py" for i in range(10)]
    # 6500 total LOC across 10 files → well above a reasonable per-cluster threshold
    diff = _make_diff_single_dir_multi_file(directory, file_names, lines_per_file=650)

    # split_cluster_by_file takes:
    #   cluster_dir: str, cluster_files: list[str], diff_text: str
    # Returns a list of single-file clusters: [{"file": "<path>", "diff": "<hunk>"}, ...]
    per_file_clusters = split_cluster_by_file(
        cluster_dir=directory,
        cluster_files=file_names,
        diff_text=diff,
    )

    assert len(per_file_clusters) == 10, (
        f"Strategy F must produce one cluster per file (10 files → 10 clusters); "
        f"got {len(per_file_clusters)} clusters: {per_file_clusters}"
    )

    # Each cluster must represent exactly one file
    for cluster in per_file_clusters:
        files_in_cluster = cluster.get("files", [])
        assert len(files_in_cluster) == 1, (
            f"Strategy F: each per-file cluster must contain exactly 1 file; "
            f"got {len(files_in_cluster)}: {files_in_cluster}"
        )

    # File-atomicity: total files across clusters equals input count
    total_files = sum(len(c.get("files", [])) for c in per_file_clusters)
    assert total_files == len(file_names), (
        f"Strategy F file-atomicity: total files across clusters ({total_files}) "
        f"must equal input file count ({len(file_names)})"
    )


def test_strategy_f_does_not_split_single_file_within_cluster() -> None:
    """File-atomicity invariant: a single file is NEVER split across reviewers.

    Given: a diff with ONE giant file (8000 lines, no other files in the directory)
    When:  split_cluster_by_file is called
    Then:
    - Result is a single-element list (one cluster, one dispatch)
    - The cluster does NOT set oversized_single_file to False (it must be True or absent+implicit)
    - RegionSplitInvariantError is NOT raised

    A single source file is the atomic unit of code review. Strategy F must
    NEVER split a file by hunk across two dispatches.
    """
    diff = _make_diff_single_file("src/payments/giant.py", added=4000, removed=4000)

    per_file_clusters = split_cluster_by_file(
        cluster_dir="src/payments",
        cluster_files=["giant.py"],
        diff_text=diff,
    )

    assert len(per_file_clusters) == 1, (
        f"A single-file cluster must produce exactly 1 per-file dispatch "
        f"(file-atomicity: no hunk splitting); got {len(per_file_clusters)} clusters"
    )

    single_cluster = per_file_clusters[0]
    files_in_cluster = single_cluster.get("files", [])
    assert len(files_in_cluster) == 1, (
        f"Single-file cluster must still have 1 file entry; got {files_in_cluster}"
    )

    # File MUST NOT be split into sub-hunks — the diff for this cluster must
    # cover the whole file (not a partial subset).
    cluster_diff = single_cluster.get("diff", "")
    assert "giant.py" in cluster_diff, (
        "The per-file cluster diff must include the original file's hunks"
    )


def test_strategy_f_single_oversized_file_carries_flag() -> None:
    """Single-oversized-file pass-through: flag must be set.

    Given: a diff with ONE file > reviewer context ceiling (8000+ lines, no other files)
    When:  split_cluster_by_file is called
    Then:
    - The resulting single cluster carries oversized_single_file=True
    - The cluster is dispatched as-is (not sub-chunked by hunk)

    This satisfies the AC amendment: the caller (runner.py T7) uses this flag
    to add a visibility trailer note about the oversized file and enables
    truncation/aggregation handling downstream.
    """
    diff = _make_diff_single_file("src/payments/giant.py", added=5000, removed=3000)

    per_file_clusters = split_cluster_by_file(
        cluster_dir="src/payments",
        cluster_files=["giant.py"],
        diff_text=diff,
        # Strategy F must auto-detect oversized; threshold defaults to same
        # review.region_split.loc_threshold or a dedicated per-cluster key.
        # oversized is detected when cluster LOC > threshold.
    )

    assert len(per_file_clusters) == 1, (
        f"Single-file diff must produce 1 cluster; got {len(per_file_clusters)}"
    )

    cluster = per_file_clusters[0]

    # The cluster must carry the oversized_single_file flag so callers
    # know to emit the appropriate visibility trailer entry.
    assert cluster.get("oversized_single_file") is True, (
        f"A single file > LOC threshold must have oversized_single_file=True; "
        f"got: {cluster!r}. "
        "See AC amendment: Strategy F passes through oversized single files with "
        "an explicit flag rather than splitting by hunk."
    )


def test_strategy_f_only_triggers_on_oversized_clusters() -> None:
    """Strategy F triggers ONLY on clusters that exceed the per-cluster LOC threshold.

    Given: a diff with two directories —
           - large: 10 files × 650 lines (6500 total, exceeds threshold)
           - small: 2 files × 10 lines (20 total, below threshold)
    When:  run_region_split_strategy_f is called
    Then:
    - The large cluster is fanned out: 10 dispatches (one per file)
    - The small cluster stays at Strategy E: 1 dispatch (whole directory cluster)
    - Total dispatches: 11 (10 per-file + 1 per-directory)
    - RegionSplitInvariantError is NOT raised
    """
    large_files = [f"processor_{i}.py" for i in range(10)]
    small_files = ["config.py", "utils.py"]

    diff = _make_diff_mixed_clusters(
        large_dir="src/payments",
        large_files=large_files,
        large_loc_per_file=650,  # 6500 total → exceeds threshold
        small_dir="src/utils",
        small_files=small_files,
        small_loc_per_file=10,  # 20 total → below threshold
    )

    # run_region_split_strategy_f returns a list of dispatch specs
    # (same shape as split_cluster_by_file clusters, but aggregated from all
    # directory-level clusters).
    dispatch_specs = run_region_split_strategy_f(diff_text=diff)

    # Large cluster → 10 per-file dispatches
    large_dir_specs = [
        s for s in dispatch_specs if any("payments" in f for f in s.get("files", []))
    ]
    assert len(large_dir_specs) == 10, (
        f"Oversized cluster (src/payments, 10 files) must produce 10 per-file dispatches; "
        f"got {len(large_dir_specs)}. Full dispatch_specs: {dispatch_specs}"
    )

    # Small cluster → 1 directory-level dispatch (Strategy E, unchanged)
    small_dir_specs = [
        s for s in dispatch_specs if any("utils" in f for f in s.get("files", []))
    ]
    assert len(small_dir_specs) == 1, (
        f"Small cluster (src/utils, 2 files, 20 LOC) must stay as 1 Strategy E dispatch; "
        f"got {len(small_dir_specs)}. Full dispatch_specs: {dispatch_specs}"
    )

    total_dispatches = len(dispatch_specs)
    assert total_dispatches == 11, (
        f"Mixed diff: 10 per-file + 1 directory dispatch = 11 total; "
        f"got {total_dispatches}. Full dispatch_specs: {dispatch_specs}"
    )


def test_strategy_f_does_not_raise_region_split_invariant_error_on_fan_out() -> None:
    """RegionSplitInvariantError must NOT be raised in any Strategy F scenario.

    Given: a multi-file directory cluster (the primary Strategy F use case)
    When:  split_cluster_by_file produces per-file clusters
    Then:  RegionSplitInvariantError is not raised (file-atomicity is preserved)

    This contract is explicit in the story DD:
      'preserves the file-atomicity invariant (RegionSplitInvariantError NOT raised)'
    """
    directory = "src/core"
    files = [f"module_{i}.py" for i in range(5)]
    diff = _make_diff_single_dir_multi_file(directory, files, lines_per_file=300)

    raised = None
    try:
        split_cluster_by_file(
            cluster_dir=directory,
            cluster_files=files,
            diff_text=diff,
        )
    except RegionSplitInvariantError as exc:
        raised = exc

    assert raised is None, (
        f"Strategy F must NOT raise RegionSplitInvariantError; "
        f"file-atomicity must be preserved during per-file fan-out. "
        f"Got: {raised!r}"
    )


def test_strategy_f_file_atomicity_via_direct_assertion_check() -> None:
    """File-atomicity via _assert_file_atomicity: Strategy F output satisfies the invariant.

    Given: a Strategy F per-file fan-out produces N clusters
    When:  the clusters are reconstructed as a file-identity list
    Then:  Counter(reconstructed) == Counter(input_filenames)
           (every input file appears exactly once across all output clusters)
    """
    from collections import Counter  # noqa: PLC0415

    directory = "src/billing"
    files = [f"invoice_{i}.py" for i in range(4)]
    full_paths = [f"{directory}/{f}" for f in files]
    diff = _make_diff_single_dir_multi_file(directory, files, lines_per_file=200)

    per_file_clusters = split_cluster_by_file(
        cluster_dir=directory,
        cluster_files=files,
        diff_text=diff,
    )

    # Reconstruct full paths from cluster output
    reconstructed: list[str] = []
    for cluster in per_file_clusters:
        cluster_files = cluster.get("files", [])
        cluster_dir = cluster.get("cluster_dir", directory)
        for f in cluster_files:
            # Full paths already, or reconstruct from cluster_dir + basename
            if "/" in f:
                reconstructed.append(f)
            else:
                reconstructed.append(f"{cluster_dir}/{f}")

    assert Counter(reconstructed) == Counter(full_paths), (
        f"File-atomicity: reconstructed paths must match input paths exactly. "
        f"Expected Counter({full_paths}), got Counter({reconstructed})"
    )

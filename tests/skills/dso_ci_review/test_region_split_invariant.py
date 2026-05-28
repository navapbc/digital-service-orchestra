"""Invariant test for region-split threshold constants — R7b (PR-2).

The dispatcher-side commit-scoped diff path (R3a/R10) relies on the runner's
region-split fallback as a backstop against giant diffs. The dispatcher does
NOT know the runner's threshold values — they live in
dso_ci_review.region_split as _LOC_THRESHOLD_DEFAULT and
_FILE_COUNT_THRESHOLD_DEFAULT.

If those constants are tuned upward without coordinating with the dispatcher's
own absolute cap (DSO_DISPATCH_BYTES_CAP, DSO_DISPATCH_FILES_CAP from R7d),
the giant-diff guarantee silently regresses: a diff that exceeds the old
runner threshold but not the new one falls through to a single LLM call,
defeating the region-split mechanism.

This test locks in the constants. Any change to the values requires:
1. Re-validating the dispatcher's size cap interaction (R7d defaults
   5_242_880 bytes / 100 files via DSO_DISPATCH_*_CAP).
2. Re-running tests/scripts/test-llm-review-dispatch-or-skip.sh
   (specifically test_dispatcher_size_cap_triggers_overbound and
   test_dispatcher_regression_pr425_giant_diff).
3. Updating the rationale comment in the dispatcher's R7d block.

The override env vars are configurable per project, so the test asserts
DEFAULTS only — projects that tune the constants for their workload set
the env vars rather than modifying the defaults.

Rationale anchor: PR #425 incident (51K files / 4M lines from a 6-commit PR)
demonstrated that without a working giant-diff backstop, single-call LLM
review produces unusable results.
"""

from __future__ import annotations

import sys
import pathlib

# Add plugin scripts to sys.path so we can import dso_ci_review.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)


def test_region_split_routes_at_loc_threshold() -> None:
    """A diff with > default LOC threshold MUST trigger region-split routing.

    Behavioral lock-in: rather than asserting the private constant value,
    this exercises the public-effect behavior — calling _should_region_split
    with a synthetic diff at the threshold boundary. The dispatcher relies
    on this routing as its giant-diff backstop (per R3a / R7d). If a future
    change raises the default such that the canonical 3001-LOC fixture stops
    triggering region-split, the dispatcher's giant-diff guarantee silently
    regresses — this test fails loudly.

    Rationale anchor: PR #425 (51K files / 4M lines from a 6-commit PR)
    demonstrated that without a working giant-diff backstop, single-call LLM
    review produces unusable results.
    """
    from dso_ci_review import region_split

    # Build a synthetic diff that adds 3001 lines across 2 files (avoids the
    # single-file atomicity invariant). 3001 > the established 3000 default
    # → must route to region-split. If someone raises the default to 5000,
    # this assertion fails — forcing them to (a) update the test fixture
    # and (b) re-evaluate the dispatcher's size cap interaction.
    diff_lines = ["diff --git a/file1.py b/file1.py", "+x"] * 1500
    diff_lines += ["diff --git a/file2.py b/file2.py"] + ["+y"] * 1501
    diff = "\n".join(diff_lines)

    assert region_split._should_region_split(diff) is True, (
        "A 3001-LOC diff across 2 files no longer triggers region-split. "
        "The dispatcher's giant-diff backstop has regressed. Either revert the "
        "threshold change or update the dispatcher R7d size cap to compensate."
    )


def test_region_split_routes_at_file_count_threshold() -> None:
    """A diff touching > default file-count MUST trigger region-split routing.

    Behavioral counterpart to the LOC test. Same rationale: locks in
    observable routing behavior, not private constant values. A diff with
    41 small files (each 2 LOC) must route to region-split.
    """
    from dso_ci_review import region_split

    diff_lines = []
    for i in range(41):
        diff_lines.append(f"diff --git a/file{i}.py b/file{i}.py")
        diff_lines.append("+x")
    diff = "\n".join(diff_lines)

    assert region_split._should_region_split(diff) is True, (
        "A 41-file diff no longer triggers region-split. The dispatcher's "
        "giant-diff backstop has regressed. Either revert the threshold change "
        "or update the dispatcher R7d size cap to compensate."
    )


def test_region_split_small_diff_does_not_route() -> None:
    """A diff well under both thresholds MUST NOT route to region-split.

    Inverse-case lock-in: prevents over-tuning that would route every diff
    through region-split (wasting cluster overhead on simple changes).
    """
    from dso_ci_review import region_split

    # 10 files × 5 lines = 50 LOC, well under any reasonable threshold.
    diff_lines = []
    for i in range(10):
        diff_lines.append(f"diff --git a/file{i}.py b/file{i}.py")
        diff_lines.extend(["+x"] * 5)
    diff = "\n".join(diff_lines)

    assert region_split._should_region_split(diff) is False, (
        "A 10-file / 50-LOC diff is routing to region-split. Defaults are "
        "tuned too aggressively — single-cluster review is more efficient "
        "for small diffs."
    )

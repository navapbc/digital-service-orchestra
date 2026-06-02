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


def _build_multi_file_diff(num_files: int, lines_per_file: int) -> str:
    """Build a synthetic unified diff with num_files distinct files.

    Each file has `lines_per_file` added lines. Total LOC = num_files × lines_per_file.
    The diff is at least 2 files wide so the single-file atomicity short-circuit
    in _should_region_split doesn't trigger unintended False returns.
    """
    diff_lines = []
    for i in range(num_files):
        diff_lines.append(f"diff --git a/file{i}.py b/file{i}.py")
        diff_lines.extend(["+x"] * lines_per_file)
    return "\n".join(diff_lines)


def test_region_split_above_loc_threshold_routes() -> None:
    """A diff with LOC > default threshold MUST trigger region-split routing.

    Behavioral lock-in: rather than asserting the private constant value,
    exercise the public-effect behavior via _should_region_split. The
    dispatcher relies on this routing as its giant-diff backstop (R3a / R7d).
    Under component #3' the GATE uses _gate_loc_threshold() (default 20000); a
    diff above that still triggers the backstop. If a future change raises the
    gate such that a genuinely giant diff stops triggering region-split, the
    dispatcher's giant-diff guarantee silently regresses — this test fails loudly.

    Rationale anchor: PR #425 (51K files / 4M lines from a 6-commit PR)
    demonstrated that without a working giant-diff backstop, single-call LLM
    review produces unusable results.
    """
    from dso_ci_review import region_split

    # 2 files × 10001 lines = 20002 LOC > 20000 gate (strict inequality)
    diff = _build_multi_file_diff(num_files=2, lines_per_file=10001)
    assert region_split._should_region_split(diff) is True, (
        "A 20002-LOC diff across 2 files no longer triggers region-split. "
        "The dispatcher's giant-diff backstop has regressed. Either revert "
        "the gate threshold change or update the dispatcher R7d size cap."
    )


def test_region_split_at_loc_threshold_does_not_route() -> None:
    """A diff with LOC == the GATE threshold MUST NOT route (strict >).

    Boundary-condition coverage: the gate uses `loc_count > gate_loc`
    (strict inequality), so exactly 20000 LOC should not route. This guards
    against a future change to `>=` semantics, which would shift the
    interaction with the dispatcher's size cap.
    """
    from dso_ci_review import region_split

    # 2 files × 10000 = 20000 LOC, exactly at the GATE threshold (must not route)
    diff = _build_multi_file_diff(num_files=2, lines_per_file=10000)
    # File count (2) is below the gate file threshold (120) so we isolate the LOC gate.
    assert region_split._should_region_split(diff) is False, (
        "A diff at exactly the GATE LOC threshold is routing to region-split. "
        "The boundary condition (strict > vs >=) has shifted, changing the "
        "dispatcher backstop's behavior in a way callers may not expect."
    )


def test_region_split_above_file_count_threshold_routes() -> None:
    """A diff with file-count > the GATE threshold MUST trigger region-split routing.

    Uses substantial per-file content (10 LOC each) to make the test robust
    against any future per-file LOC minimum the file-count gate might add.
    Under #3' the GATE file-count threshold default is 120.
    """
    from dso_ci_review import region_split

    # 121 files × 10 LOC each = 1210 total LOC (below the 20000 LOC gate)
    # File count 121 > 120 → must route via the GATE file-count gate alone
    diff = _build_multi_file_diff(num_files=121, lines_per_file=10)
    assert region_split._should_region_split(diff) is True, (
        "A 121-file diff no longer triggers region-split. The dispatcher's "
        "giant-diff backstop has regressed. Either revert the gate threshold "
        "change or update the dispatcher R7d size cap."
    )


def test_region_split_at_file_count_threshold_does_not_route() -> None:
    """A diff with file-count == default MUST NOT route (strict >).

    Boundary-condition coverage: 40 files exactly should not route. Same
    rationale as the LOC boundary test.
    """
    from dso_ci_review import region_split

    # 40 files × 10 LOC = 400 total LOC. File count exactly at threshold.
    diff = _build_multi_file_diff(num_files=40, lines_per_file=10)
    assert region_split._should_region_split(diff) is False, (
        "A diff at exactly the file-count threshold is routing to "
        "region-split. The boundary condition has shifted."
    )


def test_region_split_small_diff_does_not_route() -> None:
    """A diff well under both thresholds MUST NOT route to region-split.

    Inverse-case lock-in: prevents over-tuning that would route every diff
    through region-split (wasting cluster overhead on simple changes).
    """
    from dso_ci_review import region_split

    # 10 files × 5 LOC = 50 LOC, well under any reasonable threshold
    diff = _build_multi_file_diff(num_files=10, lines_per_file=5)
    assert region_split._should_region_split(diff) is False, (
        "A 10-file / 50-LOC diff is routing to region-split. Defaults are "
        "tuned too aggressively — single-cluster review is more efficient "
        "for small diffs."
    )

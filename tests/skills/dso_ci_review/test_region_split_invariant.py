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


def test_region_split_loc_threshold_default_locked() -> None:
    """The default LOC threshold for region-split must be 3000.

    Changing this without coordinating with the dispatcher's absolute size
    cap (R7d) creates a silent giant-diff regression window.
    """
    from dso_ci_review import region_split

    assert region_split._LOC_THRESHOLD_DEFAULT == 3000, (
        f"Region-split LOC default changed from 3000 to "
        f"{region_split._LOC_THRESHOLD_DEFAULT}. Re-validate dispatcher R7d "
        f"size cap interaction before updating this test."
    )


def test_region_split_file_count_threshold_default_locked() -> None:
    """The default file-count threshold for region-split must be 40.

    Changing this without coordinating with the dispatcher's absolute size
    cap (R7d) creates a silent giant-diff regression window.
    """
    from dso_ci_review import region_split

    assert region_split._FILE_COUNT_THRESHOLD_DEFAULT == 40, (
        f"Region-split file-count default changed from 40 to "
        f"{region_split._FILE_COUNT_THRESHOLD_DEFAULT}. Re-validate dispatcher "
        f"R7d size cap interaction before updating this test."
    )


def test_region_split_thresholds_configurable() -> None:
    """The thresholds must remain configurable via review.region_split.* keys.

    Hardcoding the defaults without a config override would block projects
    from tuning for their workload. This test guards against accidental
    removal of the override path.
    """
    from dso_ci_review import region_split

    # Helper functions must exist and be callable
    assert callable(region_split._loc_threshold)
    assert callable(region_split._file_count_threshold)


def test_region_split_cap_invariant_documented() -> None:
    """The region_split module docstring must reference the dispatcher cap.

    Bidirectional cross-reference: dispatcher comments R7d; runner comments
    its thresholds. A maintainer changing either side must see the other's
    constraint to make an informed decision.
    """
    from dso_ci_review import region_split

    docstring = region_split.__doc__ or ""
    # Either the module docstring or the constants block must explain the
    # cross-coupling. Loose check — we accept any of these wording variants.
    rationale_present = any(
        keyword in docstring.lower()
        for keyword in (
            "dispatcher",
            "giant-diff",
            "fallback",
            "loc_threshold",
        )
    )
    assert rationale_present, (
        "region_split.py module docstring should explain why thresholds are "
        "load-bearing for the dispatcher's giant-diff backstop."
    )

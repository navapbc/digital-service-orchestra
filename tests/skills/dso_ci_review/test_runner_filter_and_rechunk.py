"""Tests for #3' R-1 (filter-before-split) and R-2 (fallback re-chunk) seams.

Component #3' of the chunked-review FP-reduction proposal. Two runner-level
behaviors are under test here, exercised via focused, pure helpers extracted
for testability (the full main() does real LLM dispatch):

R-1 (filter before split):
  - The generated/binary file-filter runs BEFORE the should_split decision.
    The filtered reviewable file SET is computed once and feeds BOTH the gate
    decision and the chunked dispatch.
  - A generated-file-heavy diff that now reviews single-pass still has the
    generated files filtered out of the reviewed scope.
  - The diff TEXT is NOT mutated (preserving OVER_BOUND budget math and the
    visibility trailer's skipped-file list).

R-2 (fallback re-chunk):
  - When a single-pass review result carries a `fallback_exhausted`
    (context-exhaustion sentinel) finding, the diff is re-routed to the chunked
    path (run_region_split_strategy_f) instead of emitting the synthetic finding.
"""

from __future__ import annotations

import pathlib
import sys

# Ensure the plugin scripts directory is on sys.path so imports resolve.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review import runner  # noqa: E402


# ---------------------------------------------------------------------------
# Diff builders
# ---------------------------------------------------------------------------


def _file_block(path: str, loc: int) -> list[str]:
    block = [
        f"diff --git a/{path} b/{path}",
        f"--- a/{path}",
        f"+++ b/{path}",
        "@@ -1 +1 @@",
    ]
    block.extend(["+x"] * loc)
    return block


def _make_generated_heavy_diff() -> str:
    """A diff dominated by lock files (generated; filtered by DEFAULT_IGNORE_GLOBS)
    plus a couple of real source files.
    """
    lines: list[str] = []
    # Generated/lock files — default-ignored.
    lines += _file_block("frontend/package-lock.json", 50)
    lines += _file_block("backend/poetry.lock", 50)
    lines += _file_block("vendor/yarn.lock", 50)
    # Real source files — reviewable.
    lines += _file_block("src/app.py", 10)
    lines += _file_block("src/util.py", 10)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# R-1 — filter before split
# ---------------------------------------------------------------------------


def test_partition_reviewable_files_separates_generated() -> None:
    """Given: a generated-heavy diff
    When:  _partition_reviewable_files computes the reviewable/skipped sets
    Then:  the lock files land in `skipped`, the source files in `reviewable`.
    """
    diff = _make_generated_heavy_diff()
    reviewable, skipped = runner._partition_reviewable_files(diff, config={})

    skipped_paths = {p for p, _ in skipped}
    assert "frontend/package-lock.json" in skipped_paths
    assert "backend/poetry.lock" in skipped_paths
    assert "vendor/yarn.lock" in skipped_paths
    assert "src/app.py" in reviewable
    assert "src/util.py" in reviewable
    # Generated files must NOT appear in the reviewable scope.
    assert "frontend/package-lock.json" not in reviewable


def test_partition_does_not_mutate_diff_text() -> None:
    """R-1 constraint: filtering must NOT mutate the diff text (preserving the
    OVER_BOUND budget math and the visibility trailer's skipped-file list).

    _partition_reviewable_files returns file sets only; the caller keeps the
    original diff_text untouched.
    """
    diff = _make_generated_heavy_diff()
    original = diff
    runner._partition_reviewable_files(diff, config={})
    assert diff == original, "diff_text must not be mutated by filtering"


def test_gate_decision_uses_filtered_file_set() -> None:
    """R-1: the should_split gate is computed from the FILTERED reviewable set,
    so generated files do not push a diff over the file-count gate.

    Given: a diff whose TOTAL file count exceeds the gate file-count threshold
           only because of generated files; the reviewable (source) file count
           is below the gate.
    When:  _should_region_split_on_files is given the reviewable set
    Then:  returns False — single-pass (generated files excluded from the gate).
    """
    n_reviewable = 5  # well below the 120 gate file-count threshold
    n_generated = 200  # would blow past the gate if counted
    lines: list[str] = []
    for i in range(n_generated):
        lines += _file_block(f"gen/lib_{i}/package-lock.json", 1)
    for i in range(n_reviewable):
        lines += _file_block(f"src/mod_{i}.py", 1)
    diff = "\n".join(lines)

    reviewable, _skipped = runner._partition_reviewable_files(diff, config={})
    assert len(reviewable) == n_reviewable

    decision = runner._should_region_split_on_files(diff, reviewable)
    assert decision is False, (
        "The gate must be computed on the filtered reviewable set; generated "
        "files must not push the diff over the file-count gate"
    )


def test_gate_decision_fires_when_reviewable_set_large() -> None:
    """R-1 inverse: when the filtered reviewable set itself exceeds the gate,
    the gate still fires.
    """
    from dso_ci_review.region_split import _gate_file_count_threshold

    lines: list[str] = []
    count = _gate_file_count_threshold() + 5
    for i in range(count):
        lines += _file_block(f"src/mod_{i}.py", 1)
    diff = "\n".join(lines)

    reviewable, _skipped = runner._partition_reviewable_files(diff, config={})
    decision = runner._should_region_split_on_files(diff, reviewable)
    assert decision is True, (
        "A reviewable set above the gate file-count threshold must trip the gate"
    )


# ---------------------------------------------------------------------------
# R-2 — fallback re-chunk
# ---------------------------------------------------------------------------


def test_detects_fallback_exhausted_finding() -> None:
    """R-2: _result_has_fallback_exhausted returns True when a single-pass
    result carries a `fallback_exhausted` synthetic finding.
    """
    result = {
        "findings": [
            {"type": "fallback_exhausted", "agent_id": "x", "primary_model": "m"},
        ]
    }
    assert runner._result_has_fallback_exhausted(result) is True


def test_no_fallback_exhausted_on_normal_result() -> None:
    """A normal review result (real findings, no sentinel) is NOT a re-chunk trigger."""
    result = {
        "findings": [
            {"severity": "important", "title": "real finding"},
        ]
    }
    assert runner._result_has_fallback_exhausted(result) is False
    # And an empty-findings result is likewise not a trigger.
    assert runner._result_has_fallback_exhausted({"findings": []}) is False


def test_fallback_exhausted_reroutes_to_chunked_path(monkeypatch) -> None:
    """R-2 end-to-end seam: given a single-pass result carrying a
    `fallback_exhausted` finding, the re-chunk dispatcher routes the original
    diff to run_region_split_strategy_f instead of returning the synthetic finding.

    We stub run_region_split_strategy_f to assert it is called with the diff.
    """
    diff = "\n".join(_file_block("src/a.py", 5) + _file_block("src/b.py", 5))
    single_pass_result = {
        "findings": [
            {"type": "fallback_exhausted", "agent_id": "x", "primary_model": "m"},
        ]
    }

    called = {}

    def _fake_strategy_f(diff_text):
        called["diff"] = diff_text
        # A genuine re-chunk partitions the diff into MORE than one cluster —
        # that is the discriminator from an un-partitionable single-file diff.
        return [
            {"cluster_dir": "src", "files": ["src/a.py"], "diff": diff_text},
            {"cluster_dir": "src", "files": ["src/b.py"], "diff": diff_text},
        ]

    monkeypatch.setattr(runner, "run_region_split_strategy_f", _fake_strategy_f)

    specs = runner._rechunk_on_fallback_exhausted(single_pass_result, diff)
    assert called.get("diff") == diff, (
        "On a fallback_exhausted single-pass result, the original diff must be "
        "routed to run_region_split_strategy_f"
    )
    assert specs is not None and len(specs) >= 2


def test_no_rechunk_when_diff_unpartitionable() -> None:
    """R-2 discriminator: a `fallback_exhausted` result on a diff that Strategy F
    cannot partition into >1 cluster (e.g. a single-file diff) must NOT re-chunk.

    Re-dispatching the same single cluster would be identical to the failed
    single-pass review and would loop. This is a true infrastructure failure;
    the sentinel must be left in place so the all-synthetic infra-failure gate
    fires. We use a real single-file diff so the real run_region_split_strategy_f
    returns exactly one cluster.
    """
    single_file_diff = (
        "diff --git a/foo.py b/foo.py\n--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n+x\n"
    )
    result = {"findings": [{"type": "fallback_exhausted", "agent_id": "x"}]}
    specs = runner._rechunk_on_fallback_exhausted(result, single_file_diff)
    assert specs is None, (
        "An un-partitionable (single-cluster) diff must NOT re-chunk; the "
        "fallback_exhausted sentinel must remain so the infra-failure gate fires"
    )


def test_no_rechunk_when_no_fallback(monkeypatch) -> None:
    """R-2: a normal single-pass result must NOT trigger a re-chunk."""
    diff = "\n".join(_file_block("src/a.py", 5))
    normal_result = {"findings": [{"severity": "minor", "title": "x"}]}

    def _boom(diff_text):  # pragma: no cover - must not be called
        raise AssertionError("re-chunk must not fire on a normal result")

    monkeypatch.setattr(runner, "run_region_split_strategy_f", _boom)
    specs = runner._rechunk_on_fallback_exhausted(normal_result, diff)
    assert specs is None, "No re-chunk should occur when there is no fallback_exhausted"


# ---------------------------------------------------------------------------
# Fix 1 — shared large-diff budget/validation gate (_apply_large_diff_budget_gate)
#
# The R-2 re-chunk path previously dispatched re-chunked specs WITHOUT the
# OVER_BOUND budget cap (max_files/max_calls) and config validation that the
# primary region-split path applies. Fix 1 routes BOTH paths through this one
# shared gate so an R-2 re-chunk of a many-file diff hits OVER_BOUND exactly as
# the primary path would, rather than fanning out unbounded.
# ---------------------------------------------------------------------------


def _specs(n: int) -> list[dict]:
    """Build n single-file Strategy-F cluster specs."""
    return [
        {"cluster_dir": f"src/m{i}", "files": [f"src/m{i}.py"], "diff": "x"}
        for i in range(n)
    ]


def test_budget_gate_passes_specs_within_budget() -> None:
    """Within budget: the gate returns the (skip-filtered) specs and no OVER_BOUND."""
    specs = _specs(3)
    config = {"max_files": 10, "max_calls": 11, "ignore_globs": ["*.lock"]}
    filtered, over_bound = runner._apply_large_diff_budget_gate(
        specs, config, skipped_set=set()
    )
    assert over_bound is None, "within-budget specs must not produce an OVER_BOUND"
    assert len(filtered) == 3


def test_budget_gate_over_bound_when_specs_exceed_max_files() -> None:
    """Fix 1 core: when the number of re-chunked clusters exceeds the operator's
    max_files budget, the SHARED gate emits OVER_BOUND — the same outcome the
    primary region-split path produces — rather than fanning out unbounded.

    This is exactly the gate the R-2 re-chunk path now routes through, so an
    R-2 re-chunk of a many-file diff hits OVER_BOUND, not an unbounded per-file
    fan-out.
    """
    # max_files=2, max_calls=3 → low product; 5 clusters exceeds max_files.
    config = {"max_files": 2, "max_calls": 3, "ignore_globs": ["*.lock"]}
    filtered, over_bound = runner._apply_large_diff_budget_gate(
        _specs(5), config, skipped_set=set()
    )
    assert over_bound is not None, (
        "a re-chunk exceeding max_files must emit OVER_BOUND (same as the "
        "primary path), not fan out unbounded"
    )
    assert over_bound["status"] == runner.OVER_BOUND
    assert filtered == []
    assert "max_files" in over_bound["over_bound_reason"]


def test_budget_gate_over_bound_on_invalid_config() -> None:
    """Fix 1: the shared gate enforces _validate_large_diff_config — a config
    where max_calls < max_files + 1 yields an OVER_BOUND output, identically for
    the primary path and the R-2 re-chunk path.
    """
    config = {"max_files": 5, "max_calls": 3, "ignore_globs": ["*.lock"]}
    filtered, over_bound = runner._apply_large_diff_budget_gate(
        _specs(2), config, skipped_set=set()
    )
    assert over_bound is not None
    assert over_bound["status"] == runner.OVER_BOUND
    assert filtered == []
    assert "max_calls" in over_bound["over_bound_reason"]


def test_budget_gate_skip_filters_generated_only_specs() -> None:
    """The shared gate drops specs whose files are ALL in the skipped set, then
    applies the budget check to the surviving (reviewable) spec count.
    """
    specs = [
        {"cluster_dir": "gen", "files": ["gen/package-lock.json"], "diff": "x"},
        {"cluster_dir": "src", "files": ["src/a.py"], "diff": "x"},
        {"cluster_dir": "src", "files": ["src/b.py"], "diff": "x"},
    ]
    config = {"max_files": 10, "max_calls": 11, "ignore_globs": ["*.lock"]}
    filtered, over_bound = runner._apply_large_diff_budget_gate(
        specs, config, skipped_set={"gen/package-lock.json"}
    )
    assert over_bound is None
    filtered_dirs = [s["cluster_dir"] for s in filtered]
    assert "gen" not in filtered_dirs, "generated-only spec must be skip-filtered"
    assert len(filtered) == 2


def test_primary_and_rechunk_share_one_budget_gate() -> None:
    """Fix 1 anti-regression: the runner must call _apply_large_diff_budget_gate
    from BOTH the primary region-split dispatch and the R-2 re-chunk dispatch.

    Guards against a future edit that reintroduces an unguarded inline budget
    check on one path. We assert the shared helper is invoked at least twice in
    the runner source (once per path).
    """
    import inspect

    src = inspect.getsource(runner.main)
    call_count = src.count("_apply_large_diff_budget_gate(")
    assert call_count >= 2, (
        "both the primary region-split path and the R-2 re-chunk path must route "
        f"through _apply_large_diff_budget_gate; found {call_count} call site(s)"
    )

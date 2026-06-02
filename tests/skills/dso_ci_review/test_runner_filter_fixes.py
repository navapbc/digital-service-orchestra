"""Tests for the #3'+#2 integration CI-review FP fixes (findings 1-3).

These exercise the runner-level fixes applied on top of the combined
component #3' (region-split gate raise/decouple + filter-before-split + R-2
re-chunk) and #2 (cross-chunk symbol injection) change:

Fix 1 — config_path threading. ``_load_filter_config(None)`` returns ALL
  defaults (it does NOT auto-resolve the repo config the way read_config_int
  does), so operator ``review.file_filter.*`` overrides were silently ignored
  by the gate/dispatch path. The runner must resolve the config path so the
  overrides take effect.

Fix 2 — OVER_BOUND call-budget math. The total LLM call count
  (dispatches + 1 aggregation) must be enforced against the operator's
  ``max_calls`` budget DISTINCTLY from the cluster-count (``max_files``) cap.
  A low ``max_calls`` must trip OVER_BOUND on a spec count that does NOT trip
  ``max_files``, and the +1 aggregation call must be accounted for.

Fix 3 — mixed-cluster spec pruning. A directory-level (Strategy-E) spec whose
  files are a MIX of reviewable + skipped (generated/ignored) files must have
  the skipped files pruned from both ``spec['files']`` and ``spec['diff']``
  before dispatch, so out-of-scope files are never sent to the LLM.

All tests are behavioral: they assert observable config-honoring / budget /
pruning outcomes, not source structure.
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
# Fix 1 — config_path threading: operator review.file_filter.* overrides honored
# ---------------------------------------------------------------------------


def test_resolve_large_diff_config_reads_repo_config_when_path_none(
    tmp_path, monkeypatch
) -> None:
    """Fix 1 core: with config_path=None, the runner must STILL resolve the
    repo's dso-config.conf so operator review.file_filter.* overrides apply.

    Regression target: _load_filter_config(None) returns all-default config and
    never reads the repo config, so a configured max_files/max_calls override
    was silently ignored by the gate/dispatch path.
    """
    config_file = tmp_path / "dso-config.conf"
    config_file.write_text(
        "review.file_filter.max_files=2\n"
        "review.file_filter.max_calls=3\n"
        "review.file_filter.ignore.glob=*.snap\n"
    )
    # runner binds default_config_path by name (from ... import default_config_path),
    # so patch the name on the runner module — patching _config has no effect.
    monkeypatch.setattr(runner, "default_config_path", lambda: str(config_file))

    resolved = runner._resolve_large_diff_config(None)

    assert resolved["max_files"] == 2, (
        "operator review.file_filter.max_files override must be honored even "
        "when the dispatch path resolves config_path itself (was None)"
    )
    assert resolved["max_calls"] == 3, (
        "operator review.file_filter.max_calls override must be honored"
    )
    assert "*.snap" in resolved["ignore_globs"], (
        "operator review.file_filter.ignore.glob override must be honored"
    )


def test_resolve_large_diff_config_honors_explicit_path(tmp_path) -> None:
    """Fix 1: an explicit config_path is read verbatim (no override of caller
    intent)."""
    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.file_filter.max_files=7\n")

    resolved = runner._resolve_large_diff_config(str(config_file))
    assert resolved["max_files"] == 7


def test_resolve_large_diff_config_defaults_when_no_config(
    tmp_path, monkeypatch
) -> None:
    """Fix 1: with no repo config present, resolution falls back to defaults
    (None max_files/max_calls) rather than raising."""
    missing = tmp_path / "absent.conf"
    monkeypatch.setattr(runner, "default_config_path", lambda: str(missing))

    resolved = runner._resolve_large_diff_config(None)
    assert resolved["max_files"] is None
    assert resolved["max_calls"] is None


# ---------------------------------------------------------------------------
# Fix 2 — OVER_BOUND call-budget math (dispatches + 1 aggregation)
# ---------------------------------------------------------------------------


def _specs(n: int) -> list[dict]:
    """Build n single-file Strategy-F cluster specs."""
    return [
        {"cluster_dir": f"src/m{i}", "files": [f"src/m{i}.py"], "diff": "x"}
        for i in range(n)
    ]


def test_call_budget_trips_without_tripping_max_files() -> None:
    """Fix 2 core: a low max_calls trips OVER_BOUND on the TOTAL call budget
    (dispatches + 1 aggregation) for a spec count that does NOT trip the
    max_files cluster cap.

    The two caps are INDEPENDENT. To isolate the call budget we leave the
    cluster cap unset (max_files=None → "no per-file cap"; the cluster count
    is otherwise unbounded) and set only a call budget. The validation
    constraint max_calls >= max_files + 1 only fires when BOTH are set, so an
    unset max_files lets the call budget bind on its own.

    With max_calls=4 and 4 dispatches: 4 dispatches + 1 aggregation = 5 calls
    > 4, so OVER_BOUND fires on the CALL budget alone — no max_files cap in
    play.
    """
    # 4 dispatches + 1 aggregation = 5 calls > max_calls=4 → trips.
    config_trips = {"max_files": None, "max_calls": 4, "ignore_globs": ["*.lock"]}
    filtered, over_bound = runner._apply_large_diff_budget_gate(
        _specs(4), config_trips, skipped_set=set()
    )
    assert over_bound is not None, (
        "the call budget (dispatches + 1 aggregation) must be enforced "
        "distinctly from the max_files cluster cap; 4 dispatches + 1 = 5 calls "
        "exceeds max_calls=4 even though no max_files cap is set"
    )
    assert over_bound["status"] == runner.OVER_BOUND
    assert "call budget" in over_bound["over_bound_reason"].lower(), (
        "the OVER_BOUND reason must identify the call-budget breach distinctly "
        f"from the cluster cap; got: {over_bound['over_bound_reason']!r}"
    )
    assert filtered == []

    # Boundary: 4 dispatches + 1 aggregation = 5 calls == max_calls=5 → within
    # budget (proves the cap is dispatches+1, not dispatches).
    config_ok = {"max_files": None, "max_calls": 5, "ignore_globs": ["*.lock"]}
    f_ok, ob_ok = runner._apply_large_diff_budget_gate(
        _specs(4), config_ok, skipped_set=set()
    )
    assert ob_ok is None, (
        "4 dispatches + 1 aggregation = 5 calls is exactly within max_calls=5"
    )
    assert len(f_ok) == 4


def test_call_budget_accounts_for_plus_one_aggregation() -> None:
    """Fix 2: the +1 aggregation call is accounted for. With N dispatches the
    budget consumed is N+1; a config with max_calls == N must trip (N+1 > N),
    while max_calls == N+1 must pass (N+1 == N+1, within budget).

    max_files is left unset so only the call budget binds (isolating the +1).
    """
    n = 5
    # max_calls exactly == dispatches: N+1 aggregation pushes over → OVER_BOUND.
    cfg_tight = {"max_files": None, "max_calls": n, "ignore_globs": ["*.lock"]}
    _f1, ob_tight = runner._apply_large_diff_budget_gate(
        _specs(n), cfg_tight, skipped_set=set()
    )
    assert ob_tight is not None, (
        f"{n} dispatches + 1 aggregation = {n + 1} calls must exceed "
        f"max_calls={n}"
    )
    assert "call budget" in ob_tight["over_bound_reason"].lower()

    # max_calls == dispatches + 1: exactly within the call budget → pass.
    cfg_ok = {"max_files": None, "max_calls": n + 1, "ignore_globs": ["*.lock"]}
    f_ok, ob_ok = runner._apply_large_diff_budget_gate(
        _specs(n), cfg_ok, skipped_set=set()
    )
    assert ob_ok is None, (
        f"{n} dispatches + 1 aggregation = {n + 1} calls is within "
        f"max_calls={n + 1}; must NOT trip OVER_BOUND"
    )
    assert len(f_ok) == n


def test_max_files_cap_still_independently_enforced() -> None:
    """Fix 2 anti-regression: the cluster-count cap (max_files) remains an
    independent gate. A spec count above max_files trips OVER_BOUND even when
    the call budget (max_calls) is generous.
    """
    config = {"max_files": 2, "max_calls": 100, "ignore_globs": ["*.lock"]}
    filtered, over_bound = runner._apply_large_diff_budget_gate(
        _specs(5), config, skipped_set=set()
    )
    assert over_bound is not None, "5 clusters must exceed max_files=2"
    assert over_bound["status"] == runner.OVER_BOUND
    assert "cluster" in over_bound["over_bound_reason"].lower(), (
        "the cluster-count cap breach must be identified distinctly from the "
        f"call budget; got: {over_bound['over_bound_reason']!r}"
    )
    assert "max_files" in over_bound["over_bound_reason"]
    assert filtered == []


# ---------------------------------------------------------------------------
# Fix 3 — mixed-cluster spec pruning (drop skipped files from files + diff)
# ---------------------------------------------------------------------------


def _mixed_spec() -> dict:
    """A single directory-level (Strategy-E) spec mixing one reviewable source
    file and one generated/ignored file, with a combined diff covering both.
    """
    diff = "\n".join(
        [
            "diff --git a/src/app.py b/src/app.py",
            "--- a/src/app.py",
            "+++ b/src/app.py",
            "@@ -1 +1 @@",
            "+real change",
            "diff --git a/src/data.lock b/src/data.lock",
            "--- a/src/data.lock",
            "+++ b/src/data.lock",
            "@@ -1 +1 @@",
            "+generated junk",
        ]
    )
    return {
        "cluster_dir": "src",
        "files": ["src/app.py", "src/data.lock"],
        "diff": diff,
        "oversized_single_file": False,
    }


def test_mixed_spec_prunes_skipped_file_from_files_and_diff() -> None:
    """Fix 3 core: a mixed spec (one reviewable + one generated file) dispatches
    with ONLY the reviewable file in `files` AND only its hunks in `diff`.

    Regression target: the skip-filter only DROPPED a spec when ALL its files
    were skipped; for a mixed spec the generated file's path and diff hunks
    remained and were sent to the LLM.
    """
    spec = _mixed_spec()
    config = {"max_files": 10, "max_calls": 11, "ignore_globs": ["*.lock"]}
    filtered, over_bound = runner._apply_large_diff_budget_gate(
        [spec], config, skipped_set={"src/data.lock"}
    )
    assert over_bound is None
    assert len(filtered) == 1
    pruned = filtered[0]

    # The generated file must be gone from the files list.
    assert pruned["files"] == ["src/app.py"], (
        "skipped (generated) files must be pruned from spec['files']"
    )
    # The generated file's hunks must be gone from the diff.
    assert "src/data.lock" not in pruned["diff"], (
        "skipped file hunks must be trimmed from spec['diff']"
    )
    assert "generated junk" not in pruned["diff"], (
        "the generated file's diff content must not survive pruning"
    )
    # The reviewable content must remain.
    assert "src/app.py" in pruned["diff"]
    assert "real change" in pruned["diff"]


def test_all_skipped_spec_still_fully_dropped() -> None:
    """Fix 3 anti-regression: a spec whose files are ALL skipped is still
    dropped entirely (the prior behavior is preserved)."""
    spec = {
        "cluster_dir": "gen",
        "files": ["gen/a.lock", "gen/b.lock"],
        "diff": "diff --git a/gen/a.lock b/gen/a.lock\n@@ @@\n+x",
    }
    config = {"max_files": 10, "max_calls": 11, "ignore_globs": ["*.lock"]}
    filtered, over_bound = runner._apply_large_diff_budget_gate(
        [spec], config, skipped_set={"gen/a.lock", "gen/b.lock"}
    )
    assert over_bound is None
    assert filtered == [], "an all-skipped spec must be dropped entirely"


def test_fully_reviewable_spec_unchanged() -> None:
    """Fix 3: a spec with no skipped files passes through with files and diff
    intact (pruning is a no-op when nothing is skipped)."""
    spec = _mixed_spec()
    original_files = list(spec["files"])
    original_diff = spec["diff"]
    config = {"max_files": 10, "max_calls": 11, "ignore_globs": ["*.lock"]}
    filtered, over_bound = runner._apply_large_diff_budget_gate(
        [spec], config, skipped_set=set()
    )
    assert over_bound is None
    assert len(filtered) == 1
    assert filtered[0]["files"] == original_files
    assert filtered[0]["diff"] == original_diff

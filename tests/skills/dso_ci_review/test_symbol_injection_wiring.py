"""Wiring tests for component #2 — symbol injection through the chunked path.

Behavioral contracts (observable, not source-structure):
  W-1. ``run_region_split_strategy_f`` returns specs that carry the cross-chunk
       symbol-injection appendix on the chunk that references a sibling-defined
       symbol — proving the deterministic pre-dispatch step runs in the chunked
       path.
  W-2. Annotation is ADDITIVE: the per-cluster diff text and the LOC the
       OVER_BOUND budget is computed from are unchanged by injection.
  W-3. ``runner._compose_review_context`` preserves the base "ci" context and
       appends the appendix (the injection is carried as read-only review_context,
       never folded into the diff).
"""

from __future__ import annotations

import pathlib
import sys

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review import _config as cfg_mod  # noqa: E402
from dso_ci_review import region_split as rs  # noqa: E402
from dso_ci_review import runner as rn  # noqa: E402


def _force_chunk_config(tmp_path, monkeypatch) -> None:
    """Lower the fan-out loc_threshold so a modest diff chunks per-file, and use
    an isolated empty default config otherwise.

    Hermeticity: in addition to overriding default_config_path (the only config
    seam the wiring exposes), pin HOME and clear git's global-config override at
    the tmp dir. The current config reader (_config.read_config_int/bool) derives
    its path from __file__ and reads NO environment variables, so this is
    defense-in-depth — it keeps the wiring test independent of the CI runner's
    environment if the reader ever grows an env fallback.
    """
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("GIT_CONFIG_GLOBAL", raising=False)
    config_file = tmp_path / "dso-config.conf"
    # loc_threshold low → each directory cluster with >threshold LOC fans out.
    config_file.write_text("review.region_split.loc_threshold=5\n")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))


def _two_chunk_cross_ref_diff() -> str:
    """A diff in two directories: dir A defines `compute_total`, dir B calls it."""
    a_lines = [
        "diff --git a/src/a/calc.py b/src/a/calc.py",
        "--- a/src/a/calc.py",
        "+++ b/src/a/calc.py",
        "@@ -0,0 +1,6 @@",
        "+def compute_total(items, tax_rate):",
        "+    subtotal = sum(items)",
        "+    return subtotal * (1 + tax_rate)",
        "+",
        "+def _unused_a():",
        "+    return 0",
    ]
    b_lines = [
        "diff --git a/src/b/report.py b/src/b/report.py",
        "--- a/src/b/report.py",
        "+++ b/src/b/report.py",
        "@@ -0,0 +1,4 @@",
        "+def make_report(items):",
        "+    total = compute_total(items, 0.1)",
        "+    return total",
        "+    # references compute_total from sibling chunk",
    ]
    return "\n".join(a_lines + b_lines)


# ---------------------------------------------------------------------------
# W-1 — strategy F output carries the appendix
# ---------------------------------------------------------------------------


def test_strategy_f_specs_carry_cross_chunk_appendix(tmp_path, monkeypatch) -> None:
    """Given: a diff with dir B referencing `compute_total` defined in dir A.
    When:  run_region_split_strategy_f produces dispatch specs.
    Then:  the spec for dir B carries symbol_injection_context containing dir A's
           `compute_total` definition.
    """
    _force_chunk_config(tmp_path, monkeypatch)
    diff = _two_chunk_cross_ref_diff()

    specs = rs.run_region_split_strategy_f(diff_text=diff)

    # Find the spec whose diff references compute_total (the B-side caller).
    b_specs = [s for s in specs if "make_report" in s.get("diff", "")]
    assert b_specs, "expected a cluster spec for the caller file"
    b_spec = b_specs[0]
    ctx = b_spec.get("symbol_injection_context")
    assert ctx, "caller chunk must carry the cross-chunk symbol appendix"
    assert "compute_total" in ctx
    assert "def compute_total(items, tax_rate):" in ctx, (
        "the sibling definition (with arity) must be injected so a reviewer "
        "does not hallucinate a missing reference"
    )
    assert "src/a/calc.py" in ctx


def test_strategy_f_appendix_absent_when_no_cross_chunk_reference(
    tmp_path, monkeypatch
) -> None:
    """A chunk that references nothing cross-chunk carries no appendix."""
    _force_chunk_config(tmp_path, monkeypatch)
    diff = _two_chunk_cross_ref_diff()

    specs = rs.run_region_split_strategy_f(diff_text=diff)
    # The DEFINER chunk (dir A) does not reference any sibling-defined symbol.
    a_specs = [s for s in specs if "compute_total(items, tax_rate)" in s.get("diff", "")]
    assert a_specs
    assert not a_specs[0].get("symbol_injection_context"), (
        "the definer chunk references no cross-chunk symbol — no appendix"
    )


# ---------------------------------------------------------------------------
# W-2 — additive: diff and budget LOC untouched
# ---------------------------------------------------------------------------


def test_injection_does_not_change_cluster_diff_text(tmp_path, monkeypatch) -> None:
    """The per-cluster diff (what the OVER_BOUND budget LOC is computed from) is
    byte-identical whether or not injection ran.
    """
    _force_chunk_config(tmp_path, monkeypatch)
    diff = _two_chunk_cross_ref_diff()

    specs_with = rs.run_region_split_strategy_f(diff_text=diff)

    # Disable injection and re-run; the diff fields must match exactly.
    config_file = tmp_path / "dso-config-off.conf"
    config_file.write_text(
        "review.region_split.loc_threshold=5\n"
        "review.region_split.symbol_injection=false\n"
    )
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))
    specs_without = rs.run_region_split_strategy_f(diff_text=diff)

    diffs_with = sorted(s["diff"] for s in specs_with)
    diffs_without = sorted(s["diff"] for s in specs_without)
    assert diffs_with == diffs_without, (
        "injection must not alter the per-cluster diff text (OVER_BOUND budget "
        "is computed on the diff, not the appendix)"
    )
    # And the disabled run must carry no appendix at all.
    assert all("symbol_injection_context" not in s for s in specs_without)


# ---------------------------------------------------------------------------
# W-3 — review_context composition preserves base + appends injection
# ---------------------------------------------------------------------------


def test_compose_review_context_preserves_base_and_appends_injection() -> None:
    composed = rn._compose_review_context("ci", "## INJECTED APPENDIX")
    assert composed is not None
    assert "ci" in composed, "base review_context must be preserved"
    assert "## INJECTED APPENDIX" in composed, "the appendix must be appended"


def test_compose_review_context_base_only() -> None:
    assert rn._compose_review_context("ci", None) == "ci"


def test_compose_review_context_injection_only() -> None:
    assert rn._compose_review_context(None, "## X") == "## X"


def test_compose_review_context_both_empty() -> None:
    assert rn._compose_review_context(None, None) is None

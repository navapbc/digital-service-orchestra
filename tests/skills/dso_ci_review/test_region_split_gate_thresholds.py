"""Tests for #3' region-split gate/fan-out threshold decoupling.

Component #3' of the chunked-review FP-reduction proposal: cross-chunk
hallucinated-reference FPs are 55% of chunked-review false positives, caused by
region_split.py splitting a diff into chunks where a reviewer can't see a
symbol/test defined in another chunk. #3' reduces how OFTEN we chunk by raising
and decoupling the region-split GATE thresholds from the per-cluster Strategy-F
FAN-OUT thresholds, so most medium-large PRs review single-pass.

Behavioral contracts under test (observable behavior, not source structure):

R-3a. The region-split GATE (`_should_region_split`) uses `_gate_loc_threshold()`
      (default ~20000), NOT `_loc_threshold()` (default 3000). A 5000-LOC /
      50-file diff therefore no longer trips the gate.
R-3b. The per-cluster Strategy-F FAN-OUT still uses the OLD `_loc_threshold()`
      (default 3000), unchanged — when forced to chunk, an oversized cluster
      still fans out per-file.
R-3c. The file-count GATE can be raised independently of any fan-out use.
Invariant. `gate_loc` MUST be > `review.size_upgrade_lines` (300); a
      misconfigured gate_loc=200 is clamped up so a region-split-eligible diff
      is always already deep-tier (preserving single-pass synthesis).
"""

from __future__ import annotations

import pathlib
import sys

# Ensure the plugin scripts directory is on sys.path so imports resolve.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review import region_split as rs  # noqa: E402
from dso_ci_review import _config as cfg_mod  # noqa: E402


# ---------------------------------------------------------------------------
# Diff builders
# ---------------------------------------------------------------------------


def _make_diff_touching_files(count: int, loc_per_file: int = 2) -> str:
    """Build a diff touching `count` distinct files with `loc_per_file` LOC each."""
    lines: list[str] = []
    for i in range(count):
        fname = f"src/module_{i}/file.py"
        lines.append(f"diff --git a/{fname} b/{fname}")
        lines.append(f"--- a/{fname}")
        lines.append(f"+++ b/{fname}")
        lines.append("@@ -1 +1 @@")
        for _ in range(loc_per_file):
            lines.append("+new")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# R-3a — the GATE no longer trips at 5000 LOC / 50 files (single-pass)
# ---------------------------------------------------------------------------


def test_gate_does_not_trip_at_5000_loc(tmp_path, monkeypatch) -> None:
    """Given: a 5000-LOC, 50-file diff (well above the OLD 3000 loc_threshold)
    When:  _should_region_split is called with default config
    Then:  returns False — the GATE now uses _gate_loc_threshold() (~20000),
           so this medium-large PR reviews single-pass (no cross-chunk blindness).
    """
    empty_config = tmp_path / "empty.conf"
    empty_config.write_text("")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(empty_config))

    # 50 files, 100 LOC each = 5000 LOC. Above OLD loc_threshold (3000) AND
    # above OLD file_count_threshold (40), but below the NEW gate thresholds.
    diff = _make_diff_touching_files(50, loc_per_file=100)
    result = rs._should_region_split(diff)
    assert result is False, (
        "GATE must NOT trip at 5000 LOC / 50 files under the raised gate "
        f"thresholds (single-pass review); got {result!r}"
    )


def test_gate_trips_above_gate_loc_threshold(tmp_path, monkeypatch) -> None:
    """Given: a diff exceeding _gate_loc_threshold() (default ~20000 LOC)
    When:  _should_region_split is called
    Then:  returns True — the gate fires only for genuinely context-pressured diffs.
    """
    empty_config = tmp_path / "empty.conf"
    empty_config.write_text("")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(empty_config))

    # 25000 LOC across 5 files (5000 LOC each) — above the default gate_loc
    # (~20000). _make_diff_touching_files emits loc_per_file lines per file.
    diff = _make_diff_touching_files(5, loc_per_file=5000)  # 25000 LOC total
    result = rs._should_region_split(diff)
    assert result is True, (
        "GATE must trip above the gate_loc threshold (~20000 LOC); "
        f"got {result!r}"
    )


def test_gate_loc_threshold_default() -> None:
    """The gate LOC threshold default is a conservative fraction of the
    30-38K Sonnet diff-content ceiling (~20000), and is strictly greater than
    the old fan-out loc_threshold default (3000).
    """
    assert rs._GATE_LOC_THRESHOLD_DEFAULT > rs._LOC_THRESHOLD_DEFAULT, (
        "gate_loc default must exceed the fan-out loc_threshold default"
    )
    assert rs._GATE_LOC_THRESHOLD_DEFAULT >= 15000, (
        "gate_loc default should be a conservative fraction of the 30-38K ceiling"
    )


def test_gate_loc_threshold_config_override(tmp_path, monkeypatch) -> None:
    """Given: a config setting review.region_split.gate_loc to 4000
    When:  a 5000-LOC / 50-file diff is checked
    Then:  the gate fires (config-overridden gate threshold honored).
    """
    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.region_split.gate_loc=4000\n")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))

    diff = _make_diff_touching_files(50, loc_per_file=100)  # 5000 LOC
    assert rs._should_region_split(diff) is True, (
        "Lowered gate_loc (4000) must make the gate fire on a 5000-LOC diff"
    )


# ---------------------------------------------------------------------------
# R-3b — the per-cluster Strategy-F FAN-OUT still uses the OLD threshold
# ---------------------------------------------------------------------------


def test_fanout_still_uses_old_loc_threshold(tmp_path, monkeypatch) -> None:
    """Given: a diff forced to chunk, with a single directory cluster whose LOC
             (5000) exceeds the OLD fan-out loc_threshold (3000) but is below the
             gate_loc (~20000).
    When:  run_region_split_strategy_f is called (the chunked path)
    Then:  the cluster fans out to one spec per file — proving the fan-out
           decision still uses _loc_threshold() (3000), NOT the raised gate value.
    """
    empty_config = tmp_path / "empty.conf"
    empty_config.write_text("")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(empty_config))

    # One directory, 5 files, 1000 LOC each = 5000 cluster LOC.
    lines: list[str] = []
    files = [f"src/pkg/file_{i}.py" for i in range(5)]
    for fname in files:
        lines.append(f"diff --git a/{fname} b/{fname}")
        lines.append(f"--- a/{fname}")
        lines.append(f"+++ b/{fname}")
        lines.append("@@ -1 +1 @@")
        for _ in range(1000):
            lines.append("+x")
    diff = "\n".join(lines)

    specs = rs.run_region_split_strategy_f(diff_text=diff)
    # Fan-out: one spec per file (5 specs), because cluster LOC (5000) >= 3000.
    assert len(specs) == len(files), (
        f"Cluster LOC 5000 >= fan-out loc_threshold 3000 must fan out per-file "
        f"({len(files)} specs); got {len(specs)}"
    )
    # Each spec carries exactly one file (file-atomicity of the fan-out).
    assert all(len(s["files"]) == 1 for s in specs), (
        "Per-file fan-out specs must each carry exactly one file"
    )


# ---------------------------------------------------------------------------
# R-3c — file-count GATE separable from fan-out
# ---------------------------------------------------------------------------


def test_file_count_gate_raised_default(tmp_path, monkeypatch) -> None:
    """Given: a 50-file diff (above the OLD file_count_threshold of 40) with low LOC
    When:  _should_region_split is called with default config
    Then:  returns False — the file-count GATE default is now raised (~120),
           so 50 small files review single-pass.
    """
    empty_config = tmp_path / "empty.conf"
    empty_config.write_text("")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(empty_config))

    diff = _make_diff_touching_files(50, loc_per_file=2)  # 100 LOC, 50 files
    assert rs._should_region_split(diff) is False, (
        "50 small files must NOT trip the raised file-count gate (single-pass)"
    )


def test_file_count_gate_trips_above_raised_default(tmp_path, monkeypatch) -> None:
    """Given: a diff touching > the raised file-count gate default
    When:  _should_region_split is called
    Then:  returns True.
    """
    empty_config = tmp_path / "empty.conf"
    empty_config.write_text("")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(empty_config))

    n = rs._gate_file_count_threshold() + 5
    diff = _make_diff_touching_files(n, loc_per_file=1)
    assert rs._should_region_split(diff) is True, (
        f"{n} files (> gate file-count threshold) must trip the gate"
    )


# ---------------------------------------------------------------------------
# Invariant — gate_loc MUST be > size_upgrade_lines (300); clamp if violated
# ---------------------------------------------------------------------------


def test_gate_loc_clamped_above_size_upgrade_lines(tmp_path, monkeypatch) -> None:
    """Given: a misconfigured review.region_split.gate_loc=200 (below the 300
             size_upgrade_lines floor that force-upgrades >=300-line diffs to deep)
    When:  _gate_loc_threshold() is read
    Then:  the value is clamped UP to at least size_upgrade_lines + 1, so a
           region-split-eligible diff is always already deep-tier (preserving
           single-pass deep synthesis).
    """
    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.region_split.gate_loc=200\n")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))

    resolved = rs._gate_loc_threshold()
    # Consolidated to the exact clamp offset (finding 6): with the default
    # size_upgrade_lines (300), the floor is max(300, 300) = 300 so gate_loc
    # clamps to exactly floor + 1.
    assert resolved == rs._SIZE_UPGRADE_LINES_FLOOR + 1, (
        f"gate_loc=200 must be clamped to exactly the size_upgrade_lines floor "
        f"+ 1 ({rs._SIZE_UPGRADE_LINES_FLOOR + 1}); got {resolved}"
    )


def test_gate_loc_clamped_at_floor_boundary_emits_warning(
    tmp_path, monkeypatch, capsys
) -> None:
    """Boundary: gate_loc == size_upgrade_lines floor (300) clamps to exactly
    floor + 1 (301) AND emits the stderr clamp warning.

    The existing clamp test uses 200 (well below the floor) and only asserts
    `> floor`. This pins the exact boundary value (the clamp predicate is
    `value <= floor`, so 300 must clamp) and the observable warning side effect.
    """
    config_file = tmp_path / "dso-config.conf"
    config_file.write_text(
        f"review.region_split.gate_loc={rs._SIZE_UPGRADE_LINES_FLOOR}\n"
    )
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))

    resolved = rs._gate_loc_threshold()
    assert resolved == rs._SIZE_UPGRADE_LINES_FLOOR + 1, (
        f"gate_loc=={rs._SIZE_UPGRADE_LINES_FLOOR} (the floor) must clamp to "
        f"exactly {rs._SIZE_UPGRADE_LINES_FLOOR + 1}; got {resolved}"
    )
    captured = capsys.readouterr()
    assert "clamping up to" in captured.err, (
        "a clamp at the floor boundary must emit the stderr clamp warning"
    )
    assert "review.region_split.gate_loc" in captured.err


def test_gate_loc_invalid_zero_falls_back_to_default(tmp_path, monkeypatch) -> None:
    """A gate_loc of 0 (would disable gating) falls back to the default."""
    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.region_split.gate_loc=0\n")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))

    assert rs._gate_loc_threshold() == rs._GATE_LOC_THRESHOLD_DEFAULT, (
        "gate_loc=0 must fall back to the default"
    )


# ---------------------------------------------------------------------------
# Fix 5 — clamp floor reads review.size_upgrade_lines dynamically.
#
# The invariant is gate_loc > review.size_upgrade_lines. The clamp floor must
# therefore track a RAISED size_upgrade_lines (so the invariant holds), while
# never dropping below the safe synchronized default (300) when an operator
# LOWERS size_upgrade_lines. Effective floor = max(300, configured) + 1.
# ---------------------------------------------------------------------------


def test_clamp_floor_respects_raised_size_upgrade_lines(tmp_path, monkeypatch) -> None:
    """Given: an operator RAISES review.size_upgrade_lines to 500 (above the
             300 default) and misconfigures gate_loc=400 (below the raised
             size_upgrade_lines, so the invariant gate_loc > size_upgrade_lines
             is violated).
    When:  _gate_loc_threshold() is read
    Then:  gate_loc is clamped UP to size_upgrade_lines + 1 (501), so a
           region-split-eligible diff is always already deep-tier — NOT merely
           to the hardcoded 301, which would still violate the invariant.
    """
    config_file = tmp_path / "dso-config.conf"
    config_file.write_text(
        "review.size_upgrade_lines=500\n"
        "review.region_split.gate_loc=400\n"
    )
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))

    resolved = rs._gate_loc_threshold()
    assert resolved == 501, (
        "a raised size_upgrade_lines (500) must raise the clamp floor so "
        f"gate_loc clamps to 501 (size_upgrade_lines + 1); got {resolved}. "
        "Clamping only to the hardcoded 301 would leave gate_loc <= "
        "size_upgrade_lines, violating the invariant."
    )


def test_clamp_floor_never_below_safe_default_when_lowered(
    tmp_path, monkeypatch
) -> None:
    """Given: an operator LOWERS review.size_upgrade_lines to 100 (below the
             300 synchronized default) and sets gate_loc=200.
    When:  _gate_loc_threshold() is read
    Then:  the clamp floor stays at the safe default (max(300, 100) = 300), so
           gate_loc clamps to 301 — a lowered size_upgrade_lines cannot drag
           the region-split gate below the safe floor.
    """
    config_file = tmp_path / "dso-config.conf"
    config_file.write_text(
        "review.size_upgrade_lines=100\n"
        "review.region_split.gate_loc=200\n"
    )
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))

    resolved = rs._gate_loc_threshold()
    assert resolved == rs._SIZE_UPGRADE_LINES_FLOOR + 1 == 301, (
        "a lowered size_upgrade_lines (100) must NOT drop the clamp floor below "
        f"the safe default ({rs._SIZE_UPGRADE_LINES_FLOOR}); expected 301, "
        f"got {resolved}"
    )

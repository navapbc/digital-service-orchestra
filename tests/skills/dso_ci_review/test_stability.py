"""RED tests for dso_ci_review.stability — finding_hash, jaccard, should_halt.

All tests fail until stability.py is created (Story 45da-5043 T5).
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review.stability import finding_hash, jaccard, should_halt  # noqa: E402


# --- finding_hash tests ---

def test_finding_hash_deterministic():
    """Same finding tuple → same hash, twice in a row."""
    f = {"file": "src/foo.py", "line_range": "10-20", "category": "correctness"}
    assert finding_hash(f) == finding_hash(f)


def test_finding_hash_distinguishes_different_findings():
    """Different file/line_range/category → different hashes."""
    f1 = {"file": "src/foo.py", "line_range": "10-20", "category": "correctness"}
    f2 = {"file": "src/bar.py", "line_range": "10-20", "category": "correctness"}
    f3 = {"file": "src/foo.py", "line_range": "30-40", "category": "correctness"}
    f4 = {"file": "src/foo.py", "line_range": "10-20", "category": "security"}
    hashes = {finding_hash(f1), finding_hash(f2), finding_hash(f3), finding_hash(f4)}
    assert len(hashes) == 4  # all different


def test_finding_hash_is_sha256_hex_not_builtin_hash():
    """Hash must be deterministic across processes (sha256 hex, not Python hash())."""
    # Run finding_hash in a fresh subprocess — Python builtin hash() is per-process randomized
    code = (
        f"import sys; sys.path.insert(0, {_SCRIPTS_DIR!r}); "
        "from dso_ci_review.stability import finding_hash; "
        "print(finding_hash({'file': 'a.py', 'line_range': '1-2', 'category': 'x'}))"
    )
    out1 = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True).stdout.strip()
    out2 = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True).stdout.strip()
    assert out1 == out2, "finding_hash must be deterministic across processes"
    # Verify it's hex (sha256-style), not a Python int
    int(out1, 16)  # raises ValueError if not hex


def test_finding_hash_normalizes_line_range_forms():
    """Tuple [12,15], list (12,15), and string '12-15' for line_range produce same hash."""
    f_str = {"file": "x.py", "line_range": "12-15", "category": "c"}
    f_list = {"file": "x.py", "line_range": [12, 15], "category": "c"}
    f_tuple = {"file": "x.py", "line_range": (12, 15), "category": "c"}
    assert finding_hash(f_str) == finding_hash(f_list) == finding_hash(f_tuple)


# --- jaccard tests ---

def test_jaccard_identical_sets():
    s = [{"file": f"{i}.py", "line_range": "1", "category": "c"} for i in range(3)]
    assert jaccard(s, s) == 1.0


def test_jaccard_disjoint_sets():
    a = [{"file": f"a{i}.py", "line_range": "1", "category": "c"} for i in range(3)]
    b = [{"file": f"b{i}.py", "line_range": "1", "category": "c"} for i in range(3)]
    assert jaccard(a, b) == 0.0


def test_jaccard_partial_overlap_three_quarters():
    a = [{"file": f"{i}.py", "line_range": "1", "category": "c"} for i in range(4)]
    b = a[:3]  # 3 of 4 overlap
    assert jaccard(a, b) == 0.75


def test_jaccard_zero_set_both_empty():
    """Both empty → 1.0 (full agreement edge case)."""
    assert jaccard([], []) == 1.0


def test_jaccard_zero_set_one_empty():
    """One empty + one non-empty → 0.0 (mathematical Jaccard of empty
    vs non-empty is no overlap). Bug da45 finding f-a1b2c3d4: returning
    1.0 here caused premature STABLE_HALT on cycle-1 transitions even
    with unresolved critical findings."""
    a = [{"file": "x.py", "line_range": "1", "category": "c"}]
    assert jaccard(a, []) == 0.0
    assert jaccard([], a) == 0.0


# --- should_halt tests ---

def test_should_halt_above_threshold():
    """Jaccard >= 0.85 → (True, 'STABLE_HALT')."""
    a = [{"file": f"{i}.py", "line_range": "1", "category": "c"} for i in range(10)]
    b = a[:9]  # 9/10 = 0.9
    halt, signal = should_halt(a, b, 0.85)
    assert halt is True
    assert signal == "STABLE_HALT"


def test_should_halt_below_threshold():
    """Jaccard < 0.85 → (False, None)."""
    a = [{"file": f"a{i}.py", "line_range": "1", "category": "c"} for i in range(10)]
    b = [{"file": f"b{i}.py", "line_range": "1", "category": "c"} for i in range(7)]
    # disjoint sets → jaccard = 0.0
    halt, signal = should_halt(a, b, 0.85)
    assert halt is False
    assert signal is None


def test_should_halt_zero_set_returns_halt():
    """Both empty → jaccard=1.0 → halt with STABLE_HALT signal."""
    halt, signal = should_halt([], [], 0.85)
    assert halt is True
    assert signal == "STABLE_HALT"


def test_should_halt_prior_empty_skips_check():
    """Prior empty (cycle-1 transition) → no halt, regardless of current
    findings. Bug da45 finding f-a1b2c3d4: premature STABLE_HALT on
    cycle-1 with unresolved critical findings used to fire because the
    zero-set 'one empty' branch returned 1.0 and exceeded the 0.85
    threshold. The prior-empty guard in should_halt now skips the check
    entirely so the dispatcher proceeds to cycle K+1."""
    current_critical = [
        {"file": "x.py", "line_range": "1", "category": "critical"},
        {"file": "y.py", "line_range": "2", "category": "critical"},
    ]
    halt, signal = should_halt(current_critical, [], 0.85)
    assert halt is False
    assert signal is None

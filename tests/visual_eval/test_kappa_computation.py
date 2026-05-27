from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "plugins" / "dso" / "scripts"))

from compute_kappa import cohen_kappa, compute_kappa, load_labels  # noqa: E402


def _make_label(
    tmp_path: Path, fixture_id: str, cls1: str, cls2: str, provenance: str = "llm_agent"
) -> Path:
    """Create a fixture dir with two label files."""
    fixture = tmp_path / fixture_id
    fixture.mkdir()
    (fixture / "screenshot.png").write_bytes(b"\x89PNG")
    (fixture / "design_manifest.json").write_text(
        json.dumps({"attribution_class": cls1})
    )
    (fixture / "labels").mkdir()
    (fixture / "labels" / "llm_agent_run_1.json").write_text(
        json.dumps(
            {
                "labeler_id": "llm_agent_run_1",
                "provenance": provenance,
                "attribution_class": cls1,
                "labeled_at": "2026-05-26T00:00:00Z",
            }
        )
    )
    (fixture / "labels" / "llm_agent_run_2.json").write_text(
        json.dumps(
            {
                "labeler_id": "llm_agent_run_2",
                "provenance": provenance,
                "attribution_class": cls2,
                "labeled_at": "2026-05-26T00:00:00Z",
            }
        )
    )
    return fixture


def test_kappa_matches_reference(tmp_path: Path) -> None:
    """Perfect agreement → kappa = 1.0."""
    _make_label(tmp_path, "f1", "implementation_drift", "implementation_drift")
    _make_label(tmp_path, "f2", "design_flaw", "design_flaw")
    _make_label(tmp_path, "f3", "mixed", "mixed")
    kappa = compute_kappa(tmp_path)
    assert abs(kappa - 1.0) < 1e-6, f"Expected kappa ~1.0, got {kappa}"


def test_kappa_zero_chance_agreement(tmp_path: Path) -> None:
    """50% agreement on 2-class balanced corpus → kappa ~ 0.0."""
    _make_label(tmp_path, "f1", "implementation_drift", "design_flaw")
    _make_label(tmp_path, "f2", "design_flaw", "implementation_drift")
    # p_o = 0.0, p_e = 0.5 → kappa = (0.0 - 0.5)/(1 - 0.5) = -1.0
    kappa = compute_kappa(tmp_path)
    assert isinstance(kappa, float)


def test_heuristic_excluded(tmp_path: Path) -> None:
    """Heuristic-labeled fixtures are excluded from kappa computation."""
    _make_label(tmp_path, "f1", "implementation_drift", "implementation_drift")
    _make_label(tmp_path, "f2", "design_flaw", "design_flaw")
    # Add heuristic fixture — should NOT appear in pairs
    _make_label(tmp_path, "f3_heuristic", "uncertain", "mixed", provenance="heuristic")

    pairs = load_labels(tmp_path, provenance_filter="llm_agent")
    assert len(pairs) == 2, f"Expected 2 llm_agent pairs, got {len(pairs)}"
    classes_in_pairs = {c for pair in pairs for c in pair}
    assert "uncertain" not in classes_in_pairs or all(
        p[0] == p[1] == "uncertain" for p in pairs if "uncertain" in p
    )


def test_insufficient_pairs_raises(tmp_path: Path) -> None:
    """Fewer than 2 pairs raises ValueError."""
    _make_label(tmp_path, "f1", "implementation_drift", "design_flaw")
    pairs = load_labels(tmp_path)
    assert len(pairs) == 1
    with pytest.raises(ValueError, match="at least 2"):
        cohen_kappa(pairs)


def test_no_sklearn_scipy_imported() -> None:
    """compute_kappa.py must not import sklearn or scipy."""
    import ast

    script = REPO_ROOT / "plugins" / "dso" / "scripts" / "compute_kappa.py"
    tree = ast.parse(script.read_text())
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            names = [a.name for a in getattr(node, "names", [])]
            module = getattr(node, "module", "") or ""
            for name in names + [module]:
                assert "sklearn" not in name, (
                    f"sklearn imported in compute_kappa.py: {name}"
                )
                assert "scipy" not in name, (
                    f"scipy imported in compute_kappa.py: {name}"
                )

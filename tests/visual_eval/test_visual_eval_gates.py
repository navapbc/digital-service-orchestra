from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "plugins" / "dso" / "scripts"))

from visual_eval_gates import (  # noqa: E402
    compute_class_skew,
    compute_hallucination_rate,
    compute_weighted_accuracy,
    run_all_gates,
)


def _make_fixture(
    tmp_path: Path,
    name: str,
    expected_class: str,
    run1_class: str = None,
    run2_class: str = None,
    findings_run1: list = None,
    findings_run2: list = None,
    run_classes: list[str] = None,
    findings_runs: list[list] = None,
) -> None:
    """Create a fixture with N runs.

    Accepts either the legacy run1_class/run2_class pair or the new run_classes list.
    run_classes takes precedence when provided.
    """
    if run_classes is None:
        # Build run_classes from legacy args, defaulting to expected_class
        _r1 = run1_class if run1_class is not None else expected_class
        _r2 = run2_class if run2_class is not None else expected_class
        run_classes = [_r1, _r2, expected_class]
    fixture = tmp_path / name
    fixture.mkdir()
    (fixture / "screenshot.png").write_bytes(b"\x89PNG")
    (fixture / "design_manifest.json").write_text(
        json.dumps({"attribution_class": expected_class})
    )
    (fixture / "labels").mkdir()
    # Handle legacy findings args for backward compatibility
    legacy_findings = [findings_run1 or [], findings_run2 or []]
    for i, cls in enumerate(run_classes, start=1):
        if findings_runs and i - 1 < len(findings_runs):
            findings = findings_runs[i - 1]
        elif i - 1 < len(legacy_findings):
            findings = legacy_findings[i - 1]
        else:
            findings = []
        label = {
            "labeler_id": f"llm_agent_run_{i}",
            "provenance": "llm_agent",
            "attribution_class": cls,
            "findings": findings,
        }
        (fixture / "labels" / f"llm_agent_run_{i}.json").write_text(json.dumps(label))


def test_variance_gate_pass(tmp_path: Path) -> None:
    # 3 runs all agree → variance = 0.0 per fixture
    _make_fixture(
        tmp_path,
        "f1",
        "implementation_drift",
        run_classes=[
            "implementation_drift",
            "implementation_drift",
            "implementation_drift",
        ],
    )
    _make_fixture(
        tmp_path,
        "f2",
        "design_flaw",
        run_classes=["design_flaw", "design_flaw", "design_flaw"],
    )
    results = run_all_gates(tmp_path)
    assert results["variance"][0] is True


def test_variance_gate_fail(tmp_path: Path) -> None:
    # 3 runs with 2 agree, 1 disagrees → variance = 1/3 ≈ 0.333 (< 0.5 threshold, PASS)
    # This test verifies that partial disagreement below threshold still passes
    _make_fixture(
        tmp_path,
        "f1",
        "implementation_drift",
        run_classes=["implementation_drift", "implementation_drift", "design_flaw"],
    )
    _make_fixture(
        tmp_path,
        "f2",
        "design_flaw",
        run_classes=["design_flaw", "design_flaw", "mixed"],
    )
    results = run_all_gates(tmp_path)
    # variance ≈ 0.333 < 0.5 threshold → PASS (not a failure case for this threshold)
    assert results["variance"][0] is True


def test_variance_gate_fail_high_disagreement(tmp_path: Path) -> None:
    # 3 runs all different → majority_fraction = 1/3, variance = 2/3 ≈ 0.667 > 0.5 → FAIL
    _make_fixture(
        tmp_path,
        "f1",
        "implementation_drift",
        run_classes=["implementation_drift", "design_flaw", "mixed"],
    )
    _make_fixture(
        tmp_path,
        "f2",
        "design_flaw",
        run_classes=["design_flaw", "mixed", "uncertain"],
    )
    results = run_all_gates(tmp_path)
    assert results["variance"][0] is False


def test_accuracy_gate_pass(tmp_path: Path) -> None:
    # 4 fixtures, all correct → accuracy = 1.0 >= 0.7
    for i, cls in enumerate(
        ["implementation_drift", "design_flaw", "mixed", "uncertain"]
    ):
        _make_fixture(tmp_path, f"f{i}", cls, cls, cls)
    assert compute_weighted_accuracy(tmp_path) >= 0.7


def test_accuracy_gate_fail(tmp_path: Path) -> None:
    # 4 fixtures, only 1 correct → accuracy = 0.25 < 0.7
    for i, cls in enumerate(
        ["implementation_drift", "design_flaw", "mixed", "uncertain"]
    ):
        wrong = "uncertain" if cls != "uncertain" else "implementation_drift"
        if i == 0:
            _make_fixture(tmp_path, f"f{i}", cls, cls, cls)
        else:
            _make_fixture(tmp_path, f"f{i}", cls, wrong, wrong)
    assert compute_weighted_accuracy(tmp_path) < 0.7


def test_skew_gate_pass(tmp_path: Path) -> None:
    # Balanced: 4 classes × 5 fixtures each = 20 fixtures, each class 25%
    for i in range(5):
        for cls in ["implementation_drift", "design_flaw", "mixed", "uncertain"]:
            _make_fixture(tmp_path, f"{cls}-{i}", cls, cls, cls)
    skew = compute_class_skew(tmp_path)
    assert all(0.10 <= p <= 0.60 for p in skew.values()), f"got {skew}"


def test_skew_gate_fail(tmp_path: Path) -> None:
    # Skewed: 9 implementation_drift + 1 design_flaw → 90% / 10% (within [10%, 60%] check)
    # Actually fail case: 1 of class X out of 20 → 5% (below 10%)
    for i in range(19):
        _make_fixture(
            tmp_path,
            f"id-{i}",
            "implementation_drift",
            "implementation_drift",
            "implementation_drift",
        )
    _make_fixture(tmp_path, "df-1", "design_flaw", "design_flaw", "design_flaw")
    skew = compute_class_skew(tmp_path)
    # implementation_drift = 19/20 = 0.95 > 0.60 → should fail
    assert not all(0.10 <= p <= 0.60 for p in skew.values())


def test_hallucination_gate_pass(tmp_path: Path) -> None:
    findings_clean = [
        {"dom_xpath_visually_consistent": True},
        {"dom_xpath_visually_consistent": True},
    ]
    _make_fixture(
        tmp_path,
        "f1",
        "implementation_drift",
        "implementation_drift",
        "implementation_drift",
        findings_run1=findings_clean,
        findings_run2=findings_clean,
    )
    rate = compute_hallucination_rate(tmp_path)
    assert rate < 0.20


def test_hallucination_gate_fail(tmp_path: Path) -> None:
    findings_bad = [{"dom_xpath_visually_consistent": False}] * 8 + [
        {"dom_xpath_visually_consistent": True}
    ] * 2
    _make_fixture(
        tmp_path,
        "f1",
        "implementation_drift",
        "implementation_drift",
        "implementation_drift",
        findings_run1=findings_bad,
        findings_run2=findings_bad,
    )
    rate = compute_hallucination_rate(tmp_path)
    assert rate >= 0.20


def test_all_gates_pass_exit_0(tmp_path: Path) -> None:
    """Integration test: script exits 0 when all gates pass on a balanced corpus."""
    for i in range(3):
        for cls in ["implementation_drift", "design_flaw", "mixed", "uncertain"]:
            _make_fixture(tmp_path, f"{cls}-{i}", cls, cls, cls)
    result = subprocess.run(
        [
            "bash",
            str(
                REPO_ROOT / "plugins" / "dso" / "scripts" / "visual-eval-calibration.sh"
            ),
            "--corpus-dir",
            str(tmp_path),
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"Script failed: {result.stdout}{result.stderr}"


def test_weights_change_accuracy(tmp_path: Path) -> None:
    """Different weight configurations produce different weighted accuracy values."""
    # 4 fixtures, 2 correct (implementation_drift class), 2 wrong (design_flaw class predicted as uncertain)
    _make_fixture(
        tmp_path,
        "id1",
        "implementation_drift",
        "implementation_drift",
        "implementation_drift",
    )
    _make_fixture(
        tmp_path,
        "id2",
        "implementation_drift",
        "implementation_drift",
        "implementation_drift",
    )
    _make_fixture(tmp_path, "df1", "design_flaw", "uncertain", "uncertain")
    _make_fixture(tmp_path, "df2", "design_flaw", "uncertain", "uncertain")

    # Equal weights: 2/4 = 0.5
    eq_acc = compute_weighted_accuracy(tmp_path, weights=None)

    # Implementation-drift-weighted heavily: 2 correct * 1.0 weight / (2*1.0 + 2*0.0) = 1.0
    id_weights = {
        "implementation_drift": 1.0,
        "design_flaw": 0.0,
        "mixed": 0.0,
        "uncertain": 0.0,
    }
    id_acc = compute_weighted_accuracy(tmp_path, weights=id_weights)

    # Design-flaw-weighted heavily: 0 correct * 1.0 / (0*1.0 + 2*1.0) = 0.0
    df_weights = {
        "implementation_drift": 0.0,
        "design_flaw": 1.0,
        "mixed": 0.0,
        "uncertain": 0.0,
    }
    df_acc = compute_weighted_accuracy(tmp_path, weights=df_weights)

    assert eq_acc != id_acc, (
        f"Equal weights ({eq_acc}) and implementation-drift weights ({id_acc}) produced same accuracy — weights not applied"
    )
    assert id_acc > df_acc, (
        f"implementation-drift-weighted ({id_acc}) should exceed design-flaw-weighted ({df_acc})"
    )


def test_script_documents_invocation_policy() -> None:
    """visual-eval-calibration.sh must document on-demand-only invocation."""
    script_path = (
        REPO_ROOT / "plugins" / "dso" / "scripts" / "visual-eval-calibration.sh"
    )
    content = script_path.read_text()
    assert "INVOCATION POLICY" in content
    assert "on-demand" in content.lower() or "not wired to per-pr ci" in content.lower()

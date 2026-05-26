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
    run1_class: str,
    run2_class: str,
    findings_run1: list = None,
    findings_run2: list = None,
) -> None:
    fixture = tmp_path / name
    fixture.mkdir()
    (fixture / "screenshot.png").write_bytes(b"\x89PNG")
    (fixture / "design_manifest.json").write_text(
        json.dumps({"attribution_class": expected_class})
    )
    (fixture / "labels").mkdir()
    label1 = {
        "labeler_id": "llm_agent_run_1",
        "provenance": "llm_agent",
        "attribution_class": run1_class,
        "findings": findings_run1 or [],
    }
    label2 = {
        "labeler_id": "llm_agent_run_2",
        "provenance": "llm_agent",
        "attribution_class": run2_class,
        "findings": findings_run2 or [],
    }
    (fixture / "labels" / "llm_agent_run_1.json").write_text(json.dumps(label1))
    (fixture / "labels" / "llm_agent_run_2.json").write_text(json.dumps(label2))


def test_variance_gate_pass(tmp_path: Path) -> None:
    _make_fixture(
        tmp_path,
        "f1",
        "implementation_drift",
        "implementation_drift",
        "implementation_drift",
    )
    _make_fixture(tmp_path, "f2", "design_flaw", "design_flaw", "design_flaw")
    results = run_all_gates(tmp_path)
    assert results["variance"][0] is True


def test_variance_gate_fail(tmp_path: Path) -> None:
    # All fixtures disagree → mean variance = 1.0 > 0.5 threshold
    _make_fixture(
        tmp_path, "f1", "implementation_drift", "implementation_drift", "design_flaw"
    )
    _make_fixture(tmp_path, "f2", "design_flaw", "design_flaw", "mixed")
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


def test_script_documents_invocation_policy() -> None:
    """visual-eval-calibration.sh must document on-demand-only invocation."""
    script_path = (
        REPO_ROOT / "plugins" / "dso" / "scripts" / "visual-eval-calibration.sh"
    )
    content = script_path.read_text()
    assert "INVOCATION POLICY" in content
    assert "on-demand" in content.lower() or "not wired to per-pr ci" in content.lower()

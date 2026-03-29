"""Structural metadata validation of skill file — design contract verification.

TDD spec for task 04e0-e5cb (RED task):
- plugins/dso/skills/fix-bug/SKILL.md must contain Gate 2c documentation:
  1. A Gate 2c section heading
  2. Reference to the gate-2c-test-regression-check.py script
  3. Documentation that Gate 1a suppression is applied via --intent-aligned flag
  4. Gate 2c positioned after investigation/fix proposal
  5. Reference to signal_type primary signal
  6. Graceful degradation documentation (failure defaults to non-blocking)
  7. Documentation of specific->specific replacement exemption

All tests fail RED because Gate 2c is not yet present in SKILL.md.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


class TestFixBugGate2cDesignContract:
    """Tests asserting the Gate 2c design contract is documented in fix-bug SKILL.md.

    Gate 2c is a post-investigation test regression analysis gate that runs after
    fix proposal and before commit. It detects when a proposed fix would loosen,
    remove, or weaken existing test assertions. These tests verify that the skill
    documents its integration, the script it delegates to, its suppression of
    Gate 1a false positives, its positioning in the workflow, its primary signal
    type, its failure fallback behavior, and the specific->specific replacement
    exemption that allows targeted value corrections without triggering the gate.
    """

    def test_gate_2c_section_exists(self) -> None:
        """SKILL.md must contain a Gate 2c section."""
        content = _read_skill()
        assert "Gate 2c" in content, (
            "Expected SKILL.md to contain 'Gate 2c' as a named gate section. "
            "Gate 2c is the post-investigation test regression analysis gate that "
            "detects when a proposed fix would weaken, remove, or loosen existing "
            "test assertions. "
            "This is a RED test — Gate 2c has not yet been added to SKILL.md."
        )

    def test_gate_2c_dispatches_script(self) -> None:
        """SKILL.md must reference gate-2c-test-regression-check.py as the Gate 2c implementation."""
        content = _read_skill()
        assert "gate-2c-test-regression-check.py" in content, (
            "Expected SKILL.md to contain 'gate-2c-test-regression-check.py' to document "
            "the script that implements the Gate 2c test regression analysis. "
            "This is a RED test — the script reference has not yet been added to SKILL.md."
        )

    def test_gate_2c_intent_suppression(self) -> None:
        """SKILL.md must document that Gate 2c suppresses false positives via Gate 1a --intent-aligned flag."""
        content = _read_skill()
        # The --intent-aligned flag is already documented for Gate 2a; require it to appear
        # in Gate 2c's section (within 800 chars of "Gate 2c") so we're testing the
        # 2c-specific suppression, not just the pre-existing 2a mention.
        gate_2c_present = "Gate 2c" in content
        if not gate_2c_present:
            assert False, (
                "Expected SKILL.md to contain 'Gate 2c'. "
                "This is a RED test — Gate 2c has not yet been added to SKILL.md."
            )
        gate_2c_section = content[
            content.index("Gate 2c") : content.index("Gate 2c") + 2000
        ]
        assert "--intent-aligned" in gate_2c_section, (
            "Expected SKILL.md to document '--intent-aligned' within the Gate 2c section "
            "to describe how Gate 1a's intent-confirmed result suppresses false-positive "
            "gate firing: when the fix corrects an assertion against documented intent, "
            "Gate 2c does not fire. Gate 1a's result is read as a boolean flag by Gate 2c. "
            "This is a RED test — the --intent-aligned suppression has not yet been documented "
            "in the Gate 2c section of SKILL.md."
        )

    def test_gate_2c_post_investigation(self) -> None:
        """Gate 2c must appear after investigation/fix proposal in SKILL.md."""
        content = _read_skill()
        assert "Gate 2c" in content, (
            "Expected SKILL.md to contain 'Gate 2c'. "
            "This is a RED test — Gate 2c has not yet been added to SKILL.md."
        )
        gate_2c_pos = content.index("Gate 2c")
        # Step 5 (fix proposal / RED test writing) must precede Gate 2c
        assert "Step 5" in content, (
            "Expected SKILL.md to contain 'Step 5' workflow step so that "
            "Gate 2c positioning can be verified as appearing after the fix proposal phase."
        )
        step5_pos = content.index("Step 5")
        assert step5_pos < gate_2c_pos, (
            f"Expected 'Step 5' (position {step5_pos}) to appear before "
            f"'Gate 2c' (position {gate_2c_pos}) in SKILL.md. "
            "Gate 2c must run after fix investigation/proposal, not before. "
            "This is a RED test — Gate 2c has not yet been positioned in SKILL.md."
        )

    def test_gate_2c_primary_signal(self) -> None:
        """SKILL.md must reference signal_type primary as the Gate 2c primary detection signal."""
        content = _read_skill()
        # signal_type is already present in the file for Gate 2a/2d; require it to appear
        # within Gate 2c's section so the test is specifically about the 2c contract.
        gate_2c_present = "Gate 2c" in content
        if not gate_2c_present:
            assert False, (
                "Expected SKILL.md to contain 'Gate 2c'. "
                "This is a RED test — Gate 2c has not yet been added to SKILL.md."
            )
        gate_2c_section = content[
            content.index("Gate 2c") : content.index("Gate 2c") + 1000
        ]
        assert "signal_type" in gate_2c_section, (
            "Expected SKILL.md to document 'signal_type' within the Gate 2c section to "
            "specify that Gate 2c emits a primary signal — when triggered, it drives a "
            "routing decision rather than merely annotating context. "
            "This is a RED test — signal_type has not yet been referenced in the Gate 2c "
            "section of SKILL.md."
        )

    def test_gate_2c_failure_fallback(self) -> None:
        """SKILL.md must document graceful degradation when gate-2c-test-regression-check.py fails."""
        content = _read_skill()
        gate_2c_present = "Gate 2c" in content
        if not gate_2c_present:
            assert False, (
                "Expected SKILL.md to contain 'Gate 2c'. "
                "This is a RED test — Gate 2c has not yet been added to SKILL.md."
            )
        gate_2c_section = content[
            content.index("Gate 2c") : content.index("Gate 2c") + 1000
        ]
        fallback_documented = (
            "triggered:false" in gate_2c_section
            or "triggered: false" in gate_2c_section
        )
        assert fallback_documented, (
            "Expected SKILL.md to document within the Gate 2c section that on error "
            "(nonzero exit, empty output, or parse failure from gate-2c-test-regression-check.py), "
            "the gate defaults to triggered:false (non-blocking) rather than hard-failing the "
            "fix workflow. This ensures graceful degradation when the regression analysis script "
            "cannot execute. "
            "This is a RED test — the failure fallback behavior has not yet been documented in SKILL.md."
        )

    def test_gate_2c_specific_specific_exemption(self) -> None:
        """SKILL.md must document that specific->specific assertion replacement does not fire Gate 2c."""
        content = _read_skill()
        gate_2c_present = "Gate 2c" in content
        if not gate_2c_present:
            assert False, (
                "Expected SKILL.md to contain 'Gate 2c'. "
                "This is a RED test — Gate 2c has not yet been added to SKILL.md."
            )
        gate_2c_section = content[
            content.index("Gate 2c") : content.index("Gate 2c") + 1200
        ]
        # Require both "specific" to appear twice OR "specific.*specific" pattern in the section,
        # capturing the concept of replacing one specific value with another specific value.
        specific_count = gate_2c_section.lower().count("specific")
        assert specific_count >= 2, (
            "Expected SKILL.md to reference 'specific' at least twice within the Gate 2c section "
            "to document the specific->specific replacement exemption: a fix that replaces one "
            "specific expected value with a different specific expected value (e.g., assertEqual('foo') "
            "→ assertEqual('bar')) proceeds without Gate 2c triggering, because assertion specificity "
            "is preserved. Only specificity-reducing changes (assertEqual → assertIn, assertion removal, "
            "assertion count reduction, skip/xfail additions) fire the gate. "
            "This is a RED test — the specific->specific exemption has not yet been documented in SKILL.md."
        )

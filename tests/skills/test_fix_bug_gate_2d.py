"""Structural metadata validation of skill file — design contract verification.

TDD spec for task c554-2687 (RED task):
- plugins/dso/skills/fix-bug/SKILL.md must contain Gate 2d documentation:
  1. A Gate 2d section heading
  2. Reference to the gate-2d-dependency-check.sh script
  3. Documentation that existing patterns do not trigger the gate
  4. Gate 2d positioned after investigation/fix proposal
  5. Reference to signal_type primary signal
  6. Graceful degradation documentation (failure defaults to non-blocking)

All tests fail RED because Gate 2d is not yet present in SKILL.md.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


class TestFixBugGate2dDesignContract:
    """Tests asserting the Gate 2d design contract is documented in fix-bug SKILL.md.

    Gate 2d is a post-investigation dependency check gate that runs after fix proposal.
    These tests verify that the skill documents its integration, the script it delegates
    to, its exemption for existing patterns, its position in the workflow, its primary
    signal type, and its failure fallback behavior.
    """

    def test_gate_2d_section_exists(self) -> None:
        """SKILL.md must contain a Gate 2d section."""
        content = _read_skill()
        assert "Gate 2d" in content, (
            "Expected SKILL.md to contain 'Gate 2d' as a named gate section. "
            "Gate 2d is the post-investigation dependency check gate that runs after "
            "fix proposal. "
            "This is a RED test — Gate 2d has not yet been added to SKILL.md."
        )

    def test_gate_2d_dispatches_script(self) -> None:
        """SKILL.md must reference gate-2d-dependency-check.sh as the Gate 2d implementation."""
        content = _read_skill()
        assert "gate-2d-dependency-check.sh" in content, (
            "Expected SKILL.md to contain 'gate-2d-dependency-check.sh' to document "
            "the script that implements the Gate 2d dependency check. "
            "This is a RED test — the script reference has not yet been added to SKILL.md."
        )

    def test_gate_2d_existing_pattern_exemption(self) -> None:
        """SKILL.md must document that existing patterns do not trigger Gate 2d."""
        content = _read_skill()
        assert (
            "existing pattern" in content
            or "existing_pattern" in content
            or "existing patterns" in content
        ), (
            "Expected SKILL.md to contain 'existing pattern' or 'existing patterns' to "
            "document that code following pre-existing dependency patterns is exempt from "
            "Gate 2d triggering, preventing false positives on established conventions. "
            "This is a RED test — the existing-pattern exemption has not yet been documented in SKILL.md."
        )

    def test_gate_2d_post_investigation(self) -> None:
        """Gate 2d must appear after investigation/fix proposal in SKILL.md."""
        content = _read_skill()
        assert "Gate 2d" in content, (
            "Expected SKILL.md to contain 'Gate 2d'. "
            "This is a RED test — Gate 2d has not yet been added to SKILL.md."
        )
        gate_2d_pos = content.index("Gate 2d")
        # Step 6 (Fix Implementation) must precede Gate 2d
        assert "Step 6" in content, (
            "Expected SKILL.md to contain Step 6 workflow step so that "
            "Gate 2d positioning can be verified relative to fix proposal."
        )
        step6_pos = content.index("Step 6")
        assert step6_pos < gate_2d_pos, (
            f"Expected 'Step 6' (position {step6_pos}) to appear before "
            f"'Gate 2d' (position {gate_2d_pos}) in SKILL.md. "
            "Gate 2d must run after investigation/fix proposal, not before. "
            "This is a RED test — Gate 2d has not yet been positioned in SKILL.md."
        )

    def test_gate_2d_primary_signal(self) -> None:
        """SKILL.md must reference signal_type primary as the Gate 2d primary detection signal."""
        content = _read_skill()
        assert "signal_type" in content, (
            "Expected SKILL.md to contain 'signal_type' to document the primary signal "
            "field emitted by gate-2d-dependency-check.sh. The primary signal type "
            "determines whether Gate 2d blocks the fix workflow. "
            "This is a RED test — signal_type has not yet been referenced in SKILL.md."
        )

    def test_gate_2d_failure_fallback(self) -> None:
        """SKILL.md must document graceful degradation when gate-2d-dependency-check.sh fails."""
        content = _read_skill()
        assert "triggered:false" in content or "triggered: false" in content, (
            "Expected SKILL.md to contain 'triggered:false' or 'triggered: false' to "
            "document Gate 2d's graceful degradation behavior: when the script exits "
            "nonzero, produces empty stdout, or yields unparseable JSON, the gate "
            "defaults to triggered:false (non-blocking) rather than hard-failing the workflow. "
            "This is a RED test — the failure fallback behavior has not yet been documented in SKILL.md."
        )

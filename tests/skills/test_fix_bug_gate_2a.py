"""Structural metadata validation of skill file — verifying design contract that Gate 2a
integration exists, not implementation logic.

TDD spec for task 2ca8-37b7 (RED task):
- plugins/dso/skills/fix-bug/SKILL.md must contain Gate 2a documentation:
  1. A Gate 2a section heading
  2. Reference to the gate-2a-reversal-check.sh script
  3. Documentation that Gate 1a suppression is applied via --intent-aligned flag
  4. Documentation of revert-of-revert recognition behavior
  5. Gate 2a positioned after investigation/fix proposal and before commit
  6. Reference to signal_type primary signal
  7. Graceful degradation documentation (nonzero exit, empty stdout, JSON parse failure -> triggered:false)

All tests fail RED because Gate 2a is not yet present in SKILL.md.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


class TestFixBugGate2aDesignContract:
    """Tests asserting the Gate 2a design contract is documented in fix-bug SKILL.md.

    Gate 2a is a post-investigation reversal check gate that runs after fix proposal
    and before commit. These tests verify that the skill documents its integration,
    the script it delegates to, its suppression of Gate 1a, its recognition of
    revert-of-revert patterns, its primary signal type, and its failure fallback behavior.
    """

    def test_gate_2a_section_exists(self) -> None:
        """SKILL.md must contain a Gate 2a section."""
        content = _read_skill()
        assert "Gate 2a" in content, (
            "Expected SKILL.md to contain 'Gate 2a' as a named gate section. "
            "Gate 2a is the post-investigation reversal check that runs after fix "
            "proposal and before commit to detect unintended reversals. "
            "This is a RED test — Gate 2a has not yet been added to SKILL.md."
        )

    def test_gate_2a_dispatches_script(self) -> None:
        """SKILL.md must reference gate-2a-reversal-check.sh as the Gate 2a implementation."""
        content = _read_skill()
        assert "gate-2a-reversal-check.sh" in content, (
            "Expected SKILL.md to contain 'gate-2a-reversal-check.sh' to document "
            "the script that implements the Gate 2a reversal detection check. "
            "This is a RED test — the script reference has not yet been added to SKILL.md."
        )

    def test_gate_2a_intent_suppression(self) -> None:
        """SKILL.md must document that Gate 2a suppresses Gate 1a via --intent-aligned flag."""
        content = _read_skill()
        assert "--intent-aligned" in content, (
            "Expected SKILL.md to contain '--intent-aligned' to document that Gate 2a "
            "suppresses Gate 1a (the pre-commit reversal gate) when a fix is confirmed "
            "intentional, preventing duplicate blocking on the same reversal. "
            "This is a RED test — the --intent-aligned flag has not yet been documented in SKILL.md."
        )

    def test_gate_2a_revert_of_revert(self) -> None:
        """SKILL.md must document that Gate 2a recognizes revert-of-revert patterns."""
        content = _read_skill()
        assert "revert-of-revert" in content, (
            "Expected SKILL.md to contain 'revert-of-revert' to document that Gate 2a "
            "recognizes when a fix intentionally reverts a prior revert (i.e., reinstates "
            "original behavior), distinguishing it from an unintended reversal. "
            "This is a RED test — revert-of-revert recognition has not yet been documented in SKILL.md."
        )

    def test_gate_2a_post_investigation(self) -> None:
        """Gate 2a must appear after investigation/fix proposal and before commit in SKILL.md."""
        content = _read_skill()
        # Gate 2a must exist at all (already tested above, but needed for position check)
        assert "Gate 2a" in content, (
            "Expected SKILL.md to contain 'Gate 2a'. "
            "This is a RED test — Gate 2a has not yet been added to SKILL.md."
        )
        gate_2a_pos = content.index("Gate 2a")
        # Step 6 (Fix Implementation) and Step 7 (Verify Fix) must precede Gate 2a
        # Step 8 (Commit and Close) must follow Gate 2a
        assert "Step 6" in content and "Step 8" in content, (
            "Expected SKILL.md to contain Step 6 and Step 8 workflow steps so that "
            "Gate 2a positioning can be verified relative to fix implementation and commit."
        )
        step8_pos = content.index("Step 8")
        assert gate_2a_pos < step8_pos, (
            f"Expected 'Gate 2a' (position {gate_2a_pos}) to appear before "
            f"'Step 8' (position {step8_pos}) in SKILL.md. "
            "Gate 2a must run after fix proposal but before the commit step. "
            "This is a RED test — Gate 2a has not yet been positioned in SKILL.md."
        )

    def test_gate_2a_primary_signal(self) -> None:
        """SKILL.md must reference signal_type primary as the Gate 2a primary detection signal."""
        content = _read_skill()
        assert "signal_type" in content, (
            "Expected SKILL.md to contain 'signal_type' to document the primary signal "
            "field emitted by gate-2a-reversal-check.sh. The primary signal type "
            "determines whether Gate 2a blocks the fix workflow. "
            "This is a RED test — signal_type has not yet been referenced in SKILL.md."
        )

    def test_gate_2a_failure_fallback(self) -> None:
        """SKILL.md must document graceful degradation when gate-2a-reversal-check.sh fails."""
        content = _read_skill()
        assert "triggered:false" in content or "triggered: false" in content, (
            "Expected SKILL.md to contain 'triggered:false' or 'triggered: false' to "
            "document Gate 2a's graceful degradation behavior: when the script exits "
            "nonzero, produces empty stdout, or yields unparseable JSON, the gate "
            "defaults to triggered:false (non-blocking) rather than hard-failing the workflow. "
            "This is a RED test — the failure fallback behavior has not yet been documented in SKILL.md."
        )

"""Tests for the updated structure of fix-cascade-recovery SKILL.md.

TDD spec for task w21-c60u (RED task):
- plugins/dso/skills/fix-cascade-recovery/SKILL.md must be updated to:
  1. Remove Step 3 (RESEARCH)
  2. Remove Step 4 (DIAGNOSE)
  3. Remove Step 5 (PLAN)
  4. Remove Step 6 (EXECUTE)
  5. Retain Step 1 (STOP) with Assess the Damage content
  6. Retain Step 2 (REVERT) with Return to Known Good State content
  7. Retain circuit breaker reset bash command
  8. Add /dso:fix-bug hand-off reference
  9. Include cascading failure context for dso:fix-bug scoring rubric
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = (
    REPO_ROOT / "plugins" / "dso" / "skills" / "fix-cascade-recovery" / "SKILL.md"
)


def _read_skill() -> str:
    return SKILL_FILE.read_text()


def test_fix_cascade_recovery_removes_step_3_research() -> None:
    """SKILL.md must not contain Step 3 RESEARCH after the refactor."""
    content = _read_skill()
    assert "### Step 3: RESEARCH" not in content, (
        "Expected SKILL.md to NOT contain '### Step 3: RESEARCH' after removing "
        "root cause analysis steps. This is a RED test — Step 3 still exists and "
        "must be removed so the skill delegates investigation to /dso:fix-bug."
    )


def test_fix_cascade_recovery_removes_step_4_diagnose() -> None:
    """SKILL.md must not contain Step 4 DIAGNOSE after the refactor."""
    content = _read_skill()
    assert "### Step 4: DIAGNOSE" not in content, (
        "Expected SKILL.md to NOT contain '### Step 4: DIAGNOSE' after removing "
        "root cause analysis steps. This is a RED test — Step 4 still exists and "
        "must be removed so the skill delegates diagnosis to /dso:fix-bug."
    )


def test_fix_cascade_recovery_removes_step_5_plan() -> None:
    """SKILL.md must not contain Step 5 PLAN after the refactor."""
    content = _read_skill()
    assert "### Step 5: PLAN" not in content, (
        "Expected SKILL.md to NOT contain '### Step 5: PLAN' after removing "
        "root cause analysis steps. This is a RED test — Step 5 still exists and "
        "must be removed so the skill delegates planning to /dso:fix-bug."
    )


def test_fix_cascade_recovery_removes_step_6_execute() -> None:
    """SKILL.md must not contain Step 6 EXECUTE after the refactor."""
    content = _read_skill()
    assert "### Step 6: EXECUTE" not in content, (
        "Expected SKILL.md to NOT contain '### Step 6: EXECUTE' after removing "
        "root cause analysis steps. This is a RED test — Step 6 still exists and "
        "must be removed so the skill delegates execution to /dso:fix-bug."
    )


def test_fix_cascade_recovery_retains_stop_step() -> None:
    """SKILL.md must retain the STOP step with Assess the Damage content."""
    content = _read_skill()
    assert "STOP" in content, (
        "Expected SKILL.md to contain 'STOP' as the first emergency step that "
        "halts all source file modifications and assesses the current damage state."
    )
    assert "Assess the Damage" in content, (
        "Expected SKILL.md to contain 'Assess the Damage' as the subtitle of the "
        "STOP step describing its purpose: understand the state before acting."
    )


def test_fix_cascade_recovery_retains_revert_step() -> None:
    """SKILL.md must retain the REVERT step with Return to Known Good State content."""
    content = _read_skill()
    assert "REVERT" in content, (
        "Expected SKILL.md to contain 'REVERT' as the second step that guides the "
        "practitioner to return to a known good state via git stash or revert."
    )
    assert "Return to Known Good State" in content, (
        "Expected SKILL.md to contain 'Return to Known Good State' as the subtitle "
        "of the REVERT step describing its purpose: establish a clean baseline."
    )


def test_fix_cascade_recovery_retains_circuit_breaker_reset() -> None:
    """SKILL.md must retain the circuit breaker reset bash command."""
    content = _read_skill()
    assert "echo 0 >" in content, (
        "Expected SKILL.md to contain 'echo 0 >' as part of the circuit breaker "
        "reset command that clears the cascade counter after recovery."
    )
    assert "/tmp/claude-cascade-" in content, (
        "Expected SKILL.md to contain '/tmp/claude-cascade-' as the path prefix "
        "for the circuit breaker state directory used by the cascade counter."
    )


def test_fix_cascade_recovery_handoff_invokes_fix_bug() -> None:
    """SKILL.md must reference /dso:fix-bug as the hand-off target for investigation."""
    content = _read_skill()
    assert "/dso:fix-bug" in content, (
        "Expected SKILL.md to contain '/dso:fix-bug' as the hand-off skill reference. "
        "After STOP and REVERT, the skill must delegate root cause analysis and "
        "implementation to /dso:fix-bug rather than duplicating those steps."
    )


def test_fix_cascade_recovery_handoff_passes_cascade_context() -> None:
    """SKILL.md must include cascading failure context for dso:fix-bug scoring rubric."""
    content = _read_skill()
    assert "cascading failure" in content, (
        "Expected SKILL.md to contain 'cascading failure' to communicate cascade "
        "context to /dso:fix-bug. The +2 modifier dimension in dso:fix-bug's scoring "
        "rubric accounts for cascading failures, so the hand-off must pass this context."
    )

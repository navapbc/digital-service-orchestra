"""Tests for content requirements of the ESCALATED section in the fix-bug SKILL.md.

TDD spec for task dso-p9i6 (RED task):
- plugins/dso/skills/fix-bug/SKILL.md ESCALATED section must:
  1. Define context slot 'escalation_history' (new slot for ESCALATED tier)
  2. Reference 'escalated-investigation-agent-1.md' prompt template file
  3. Reference 'escalated-investigation-agent-2.md' prompt template file
  4. Reference 'escalated-investigation-agent-3.md' prompt template file
  5. Reference 'escalated-investigation-agent-4.md' prompt template file
  6. Contain 'veto' within the ESCALATED section (empirical veto logic)
  7. Reference a 'resolution agent' within the ESCALATED section context
  8. Contain 'terminal' within escalation context (surface all findings language)
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


class TestEscalatedInvestigationSkillIntegration:
    """Tests asserting the ESCALATED investigation section of SKILL.md defines
    dispatch context slots, references four agent prompt files, includes veto
    logic, dispatches a resolution agent, and defines terminal escalation.

    TDD spec for task dso-p9i6 (RED task):
    - plugins/dso/skills/fix-bug/SKILL.md ESCALATED section must:
      1. Define named context slot 'escalation_history' (new slot unique to ESCALATED tier)
      2. Reference 'escalated-investigation-agent-1.md' prompt template file
      3. Reference 'escalated-investigation-agent-2.md' prompt template file
      4. Reference 'escalated-investigation-agent-3.md' prompt template file
      5. Reference 'escalated-investigation-agent-4.md' prompt template file
      6. Contain 'veto' within the ESCALATED section (empirical veto logic)
      7. Reference 'resolution agent' within the ESCALATED section context
      8. Contain 'terminal' within escalation context (surface all findings language)
    """

    def test_escalated_section_dispatch_slots_table(self) -> None:
        """SKILL.md ESCALATED section must define named context slot 'escalation_history'."""
        content = _read_skill()
        assert "escalation_history" in content, (
            "Expected SKILL.md to contain 'escalation_history' as a named context slot "
            "in the ESCALATED dispatch assembly instructions. This slot captures the "
            "investigation history from prior tiers (BASIC, INTERMEDIATE, ADVANCED) so "
            "escalated agents can avoid repeating already-attempted approaches. "
            "This is a RED test — SKILL.md does not yet define this context slot."
        )

    def test_escalated_section_references_agent_1_prompt(self) -> None:
        """SKILL.md ESCALATED section must reference the 'escalated-investigation-agent-1.md' prompt template."""
        content = _read_skill()
        assert "escalated-investigation-agent-1.md" in content, (
            "Expected SKILL.md to contain 'escalated-investigation-agent-1.md' to reference "
            "the prompt template file for Agent 1 (Web Researcher) in the ESCALATED "
            "investigation dispatch. "
            "This is a RED test — SKILL.md does not yet reference this file."
        )

    def test_escalated_section_references_agent_2_prompt(self) -> None:
        """SKILL.md ESCALATED section must reference the 'escalated-investigation-agent-2.md' prompt template."""
        content = _read_skill()
        assert "escalated-investigation-agent-2.md" in content, (
            "Expected SKILL.md to contain 'escalated-investigation-agent-2.md' to reference "
            "the prompt template file for Agent 2 (History Analyst) in the ESCALATED "
            "investigation dispatch. "
            "This is a RED test — SKILL.md does not yet reference this file."
        )

    def test_escalated_section_references_agent_3_prompt(self) -> None:
        """SKILL.md ESCALATED section must reference the 'escalated-investigation-agent-3.md' prompt template."""
        content = _read_skill()
        assert "escalated-investigation-agent-3.md" in content, (
            "Expected SKILL.md to contain 'escalated-investigation-agent-3.md' to reference "
            "the prompt template file for Agent 3 (Code Tracer) in the ESCALATED "
            "investigation dispatch. "
            "This is a RED test — SKILL.md does not yet reference this file."
        )

    def test_escalated_section_references_agent_4_prompt(self) -> None:
        """SKILL.md ESCALATED section must reference the 'escalated-investigation-agent-4.md' prompt template."""
        content = _read_skill()
        assert "escalated-investigation-agent-4.md" in content, (
            "Expected SKILL.md to contain 'escalated-investigation-agent-4.md' to reference "
            "the prompt template file for Agent 4 (Empirical Agent) in the ESCALATED "
            "investigation dispatch. "
            "This is a RED test — SKILL.md does not yet reference this file."
        )

    def test_escalated_section_veto_logic(self) -> None:
        """SKILL.md ESCALATED section must contain 'veto' for empirical veto logic."""
        content = _read_skill()
        assert "veto" in content, (
            "Expected SKILL.md to contain 'veto' to describe the empirical veto mechanism "
            "in the ESCALATED investigation section, where Agent 4 (Empirical Agent) is "
            "authorized to veto hypotheses proposed by agents 1-3. "
            "This is a RED test — the word 'veto' is not yet present in the ESCALATED stub."
        )

    def test_escalated_section_resolution_agent(self) -> None:
        """SKILL.md ESCALATED section must reference 'resolution agent' for post-veto dispatch."""
        content = _read_skill()
        assert "resolution agent" in content, (
            "Expected SKILL.md to contain 'resolution agent' to describe the agent dispatched "
            "when Agent 4 (Empirical Agent) vetoes consensus from agents 1-3. The resolution "
            "agent weighs all findings, conducts additional tests, and surfaces the "
            "highest-confidence conclusion. "
            "This is a RED test — SKILL.md does not yet reference a 'resolution agent'."
        )

    def test_escalated_section_terminal_escalation(self) -> None:
        """SKILL.md ESCALATED section must contain 'terminal' for the terminal escalation path."""
        content = _read_skill()
        assert "terminal" in content, (
            "Expected SKILL.md to contain 'terminal' to describe the terminal escalation "
            "condition when ESCALATED investigation fails — all findings are surfaced to the "
            "user and no further blind fixes are attempted. "
            "This is a RED test — SKILL.md does not yet contain terminal escalation language."
        )


class TestStep5RedTestWriterDispatch:
    """Tests asserting that fix-bug SKILL.md Step 5 references the dso:red-test-writer
    dispatch agent and the shared red-task-escalation template.

    TDD spec for task 133d-3cd9 (RED task):
    - plugins/dso/skills/fix-bug/SKILL.md Step 5 must:
      1. Reference 'dso:red-test-writer' as the agent dispatched to write the RED test
      2. Reference 'red-task-escalation' as the shared escalation template used when
         no RED test can be written
    """

    def test_step5_dispatches_red_test_writer(self) -> None:
        """SKILL.md Step 5 must reference 'dso:red-test-writer' dispatch."""
        content = _read_skill()
        assert "dso:red-test-writer" in content, (
            "Expected SKILL.md Step 5 (RED Test) to reference 'dso:red-test-writer' as the "
            "named agent dispatched to write the failing RED test. This ensures the RED test "
            "writing step uses a dedicated agent rather than inline orchestrator logic. "
            "This is a RED test — SKILL.md Step 5 does not yet reference dso:red-test-writer."
        )

    def test_step5_references_red_task_escalation_template(self) -> None:
        """SKILL.md Step 5 must reference 'red-task-escalation' shared escalation template."""
        content = _read_skill()
        assert "red-task-escalation" in content, (
            "Expected SKILL.md Step 5 (RED Test) to reference 'red-task-escalation' as the "
            "shared escalation template used when no RED test can be written and the workflow "
            "must escalate back to investigation. This template standardizes the escalation "
            "payload format across all callers of the RED test step. "
            "This is a RED test — SKILL.md Step 5 does not yet reference red-task-escalation."
        )

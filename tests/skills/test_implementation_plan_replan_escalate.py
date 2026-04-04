"""
RED tests: assert implementation-plan SKILL.md contains REPLAN_ESCALATE emission logic.

These tests MUST FAIL against the current SKILL.md (RED state).
The implementation is in a later task (bd1a-14a3 implementation phase).

Contract reference: plugins/dso/docs/contracts/replan-escalate-signal.md
"""

import pathlib

SKILL_MD = (
    pathlib.Path(__file__).parents[2]
    / "plugins/dso/skills/implementation-plan/SKILL.md"
)


def _skill_content() -> str:
    return SKILL_MD.read_text()


def test_implementation_plan_emits_replan_escalate_signal():
    """SKILL.md must contain the REPLAN_ESCALATE signal keyword."""
    content = _skill_content()
    assert "REPLAN_ESCALATE" in content, (
        "implementation-plan SKILL.md does not contain 'REPLAN_ESCALATE'. "
        "The skill must emit this signal when success criteria are contradicted or unsatisfiable."
    )


def test_implementation_plan_replan_escalate_targets_brainstorm():
    """SKILL.md must direct REPLAN_ESCALATE to the brainstorm escalation target."""
    content = _skill_content()
    assert "REPLAN_ESCALATE: brainstorm" in content, (
        "implementation-plan SKILL.md does not contain 'REPLAN_ESCALATE: brainstorm'. "
        "Per the contract, the signal must always target 'brainstorm' as the escalation route."
    )


def test_implementation_plan_replan_escalate_includes_explanation_field():
    """SKILL.md must use the canonical signal prefix including EXPLANATION: field."""
    content = _skill_content()
    assert "REPLAN_ESCALATE: brainstorm EXPLANATION:" in content, (
        "implementation-plan SKILL.md does not contain the canonical signal prefix "
        "'REPLAN_ESCALATE: brainstorm EXPLANATION:'. "
        "Per replan-escalate-signal.md, the EXPLANATION: field with colon is mandatory."
    )


def test_implementation_plan_replan_escalate_condition_contradicted_sc():
    """SKILL.md must describe the condition: contradicted or unsatisfiable success criteria."""
    content = _skill_content()
    has_contradicted = "contradict" in content.lower()
    has_unsatisfiable = (
        "unsatisfiable" in content.lower() or "cannot satisfy" in content.lower()
    )
    assert has_contradicted or has_unsatisfiable, (
        "implementation-plan SKILL.md does not mention contradicted or unsatisfiable success "
        "criteria as a condition for emitting REPLAN_ESCALATE. "
        "The skill must document when this signal is emitted (contradicted/unsatisfiable SC)."
    )


def test_implementation_plan_replan_escalate_distinguished_from_blocked():
    """SKILL.md must distinguish REPLAN_ESCALATE from STATUS:blocked."""
    content = _skill_content()
    has_status_blocked = "STATUS:blocked" in content or "STATUS: blocked" in content
    has_replan = "REPLAN_ESCALATE" in content
    assert has_status_blocked and has_replan, (
        "implementation-plan SKILL.md must distinguish REPLAN_ESCALATE from STATUS:blocked. "
        f"Found STATUS:blocked={has_status_blocked}, REPLAN_ESCALATE={has_replan}. "
        "Both must be present with guidance on when to use each signal."
    )

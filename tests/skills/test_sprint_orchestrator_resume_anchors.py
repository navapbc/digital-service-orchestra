"""Behavioral verification that sprint/SKILL.md contains ORCHESTRATOR_RESUME anchors
after every Skill("dso:implementation-plan") call site.

Bug: a7ae-5e04 — Sprint orchestrator goes idle after /dso:implementation-plan returns
STATUS:complete via Skill tool. Root cause: implementation-plan's "STOP IMMEDIATELY"
termination directive displaces the sprint orchestrator's continuation instruction
when the Skill invocation runs long (11+ min).

Fix: ORCHESTRATOR_RESUME anchor blocks after each Skill call site reassert the sprint
frame, counteracting positional attenuation with a Negative Directive.

Tests:
1. Every Skill("dso:implementation-plan") call in sprint/SKILL.md is followed by an
   ORCHESTRATOR_RESUME anchor before the SKILL_RESUMED breadcrumb.
2. implementation-plan/SKILL.md termination directive does NOT contain "STOP IMMEDIATELY"
   (replaced with scoped directive that preserves no-prose intent without halting the session).
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SPRINT_SKILL = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"
IMPL_PLAN_SKILL = REPO_ROOT / "plugins" / "dso" / "skills" / "implementation-plan" / "SKILL.md"


def _read(path: pathlib.Path) -> str:
    return path.read_text()


class TestSprintOrchestratorResumeAnchors:
    """Verify ORCHESTRATOR_RESUME anchors exist after impl-plan Skill calls."""

    def test_orchestrator_resume_anchor_exists_after_skill_calls(self) -> None:
        """Each Skill("dso:implementation-plan") must be followed by ORCHESTRATOR_RESUME."""
        content = _read(SPRINT_SKILL)
        # Find all Skill("dso:implementation-plan" call sites
        call_sites = [m.start() for m in re.finditer(
            r'Skill\("dso:implementation-plan"', content
        )]
        assert len(call_sites) >= 2, (
            f"Expected at least 2 Skill call sites, found {len(call_sites)}"
        )
        for i, pos in enumerate(call_sites):
            # Look for ORCHESTRATOR_RESUME within 500 chars after the call site
            # (before the next major section)
            window = content[pos:pos + 500]
            assert "ORCHESTRATOR_RESUME" in window, (
                f"Skill call site #{i+1} at char {pos} is missing an "
                f"ORCHESTRATOR_RESUME anchor within the next 500 characters. "
                f"This anchor prevents the agent from halting after a long "
                f"implementation-plan execution."
            )

    def test_orchestrator_resume_contains_disregard_directive(self) -> None:
        """ORCHESTRATOR_RESUME must contain a Negative Directive disregarding STOP."""
        content = _read(SPRINT_SKILL)
        assert "Disregard any STOP or termination directives" in content, (
            "ORCHESTRATOR_RESUME anchor must contain 'Disregard any STOP or "
            "termination directives' as a Negative Directive to counteract "
            "implementation-plan's termination directive."
        )

    def test_orchestrator_resume_reasserts_sprint_identity(self) -> None:
        """ORCHESTRATOR_RESUME must reassert 'You are the sprint orchestrator'."""
        content = _read(SPRINT_SKILL)
        assert "You are the sprint orchestrator" in content, (
            "ORCHESTRATOR_RESUME anchor must reassert 'You are the sprint "
            "orchestrator' to restore the agent's frame after long skill execution."
        )


class TestImplementationPlanTerminationDirective:
    """Verify termination directive is scoped to not halt the session."""

    def test_no_stop_immediately_in_termination_directive(self) -> None:
        """Termination directive must not contain 'STOP IMMEDIATELY'."""
        content = _read(IMPL_PLAN_SKILL)
        # Check specifically in the Output Protocol section
        output_protocol_start = content.find("## Output Protocol")
        assert output_protocol_start != -1, "Output Protocol section not found"
        output_section = content[output_protocol_start:]
        assert "STOP IMMEDIATELY" not in output_section, (
            "implementation-plan Output Protocol still contains 'STOP IMMEDIATELY'. "
            "This directive causes the sprint orchestrator to halt when it "
            "inline-executes implementation-plan via the Skill tool. Replace with "
            "a scoped directive that preserves no-prose intent without halting."
        )

    def test_termination_directive_has_do_not_halt(self) -> None:
        """Termination directive must contain 'Do NOT halt the session'."""
        content = _read(IMPL_PLAN_SKILL)
        output_protocol_start = content.find("## Output Protocol")
        assert output_protocol_start != -1
        output_section = content[output_protocol_start:]
        assert "Do NOT halt the session" in output_section, (
            "implementation-plan termination directive must contain "
            "'Do NOT halt the session' to prevent the sprint orchestrator "
            "from stopping when it inline-executes implementation-plan."
        )

"""Tests for INTERACTIVITY_DEFERRED brainstorm handling and replan-observability
contract reference in sprint SKILL.md.

RED tests written for ticket 28e8-34e5 (dependent on c4a2-ccf0).
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).parent.parent.parent
SPRINT_SKILL = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"


def _read_sprint_skill() -> str:
    return SPRINT_SKILL.read_text()


def _d_replan_collect_window() -> str:
    """Return the d-replan-collect subsection from Phase 2 (Implementation Planning)."""
    skill = _read_sprint_skill()
    start_marker = "d-replan-collect."
    end_marker = "e. **Post-layer-batch ticket validation**"
    start = skill.find(start_marker)
    end = skill.find(end_marker, start)
    assert start != -1, "Could not find 'd-replan-collect.' section in SKILL.md"
    assert end != -1, "Could not find end of d-replan-collect section"
    return skill[start:end]


def _phase7_step2a_window() -> str:
    """Return the Phase 7 Step 2a REPLAN_ESCALATE handling section."""
    skill = _read_sprint_skill()
    start_marker = "2a. **Handle collected REPLAN_ESCALATE stories**"
    end_marker = "3. Clear the accumulator"
    start = skill.find(start_marker)
    end = skill.find(end_marker, start)
    assert start != -1, (
        "Could not find '2a. Handle collected REPLAN_ESCALATE' in SKILL.md"
    )
    assert end != -1, "Could not find end of Phase 7 step 2a section"
    return skill[start:end]


def test_skill_md_exists():
    """Sprint SKILL.md must exist at the expected path."""
    assert SPRINT_SKILL.exists(), f"Sprint SKILL.md not found at {SPRINT_SKILL}"


def test_d_replan_collect_has_interactivity_deferred_handling():
    """d-replan-collect must include INTERACTIVITY_DEFERRED handling for non-interactive mode.

    When running in non-interactive mode and REPLAN_ESCALATE requires brainstorm,
    the orchestrator must record INTERACTIVITY_DEFERRED instead of blocking.
    """
    collect = _d_replan_collect_window()
    assert "INTERACTIVITY_DEFERRED" in collect, (
        "Sprint SKILL.md d-replan-collect section must contain INTERACTIVITY_DEFERRED handling "
        "for non-interactive mode. When brainstorm escalation is needed and the session is "
        "non-interactive, write: "
        '.claude/scripts/dso ticket comment <epic-id> "INTERACTIVITY_DEFERRED: brainstorm — '
        '<reason>. Re-run sprint interactively to address." '
        "instead of blocking for user input."
    )


def test_d_replan_collect_interactivity_deferred_skips_brainstorm():
    """INTERACTIVITY_DEFERRED handling must NOT invoke brainstorm or block for user input."""
    collect = _d_replan_collect_window()
    deferred_idx = collect.find("INTERACTIVITY_DEFERRED")
    assert deferred_idx != -1, (
        "Sprint SKILL.md d-replan-collect must contain INTERACTIVITY_DEFERRED"
    )
    # The nearby context should say skip brainstorm or continue with remaining work
    nearby = collect[deferred_idx : deferred_idx + 500]
    has_skip_indication = (
        "skip" in nearby.lower()
        or "continue" in nearby.lower()
        or "do not" in nearby.lower()
        or "do NOT" in nearby
        or "cannot block" in nearby.lower()
        or "non-interactive" in nearby.lower()
    )
    assert has_skip_indication, (
        "Sprint SKILL.md INTERACTIVITY_DEFERRED section must indicate that brainstorm "
        "is skipped/deferred and execution continues — orchestrator must NOT block waiting "
        "for user input in non-interactive mode."
    )


def test_d_replan_collect_interactivity_deferred_no_replan_resolved():
    """INTERACTIVITY_DEFERRED section must instruct NOT to write REPLAN_RESOLVED.

    The instruction 'Do NOT write REPLAN_RESOLVED' (or equivalent) must appear near
    the INTERACTIVITY_DEFERRED block, since the contract specifies INTERACTIVITY_DEFERRED
    replaces REPLAN_RESOLVED when brainstorm is deferred in non-interactive mode.
    """
    collect = _d_replan_collect_window()
    deferred_idx = collect.find("INTERACTIVITY_DEFERRED")
    assert deferred_idx != -1, (
        "Sprint SKILL.md d-replan-collect must contain INTERACTIVITY_DEFERRED"
    )
    # Verify that the nearby context explicitly says NOT to write REPLAN_RESOLVED
    nearby = collect[deferred_idx : deferred_idx + 600]
    has_do_not_write = (
        "Do NOT write" in nearby
        or "do not write" in nearby.lower()
        or "not write" in nearby.lower()
    )
    assert has_do_not_write, (
        "Sprint SKILL.md INTERACTIVITY_DEFERRED block must include an instruction not to write "
        "REPLAN_RESOLVED — per replan-observability.md contract: INTERACTIVITY_DEFERRED replaces "
        "REPLAN_RESOLVED when brainstorm escalation is deferred in non-interactive mode."
    )


def test_phase7_step2a_has_interactivity_deferred_handling():
    """Phase 7 Step 2a must also include INTERACTIVITY_DEFERRED handling for non-interactive mode."""
    step2a = _phase7_step2a_window()
    assert "INTERACTIVITY_DEFERRED" in step2a, (
        "Sprint SKILL.md Phase 7 Step 2a (out-of-scope REPLAN_ESCALATE handling) must also "
        "contain INTERACTIVITY_DEFERRED for non-interactive mode. When brainstorm escalation "
        "is needed and the session is non-interactive, record INTERACTIVITY_DEFERRED and "
        "continue rather than blocking."
    )


def test_skill_md_references_replan_observability_contract():
    """Sprint SKILL.md must reference the replan-observability contract document."""
    skill = _read_sprint_skill()
    assert "replan-observability" in skill, (
        "Sprint SKILL.md must reference the replan-observability contract "
        "(plugins/dso/docs/contracts/replan-observability.md). Add a reference in the "
        "section that documents REPLAN_TRIGGER/REPLAN_RESOLVED signal formats."
    )


def test_skill_md_interactivity_deferred_format_is_correct():
    """INTERACTIVITY_DEFERRED signal in SKILL.md must use the contract-specified format.

    Contract (replan-observability.md) specifies:
      INTERACTIVITY_DEFERRED: brainstorm — <reason>. Re-run sprint interactively to address.
    Verify both the signal prefix AND the contract-required closing phrase, plus the
    ticket comment CLI format that the orchestrator must use.
    """
    skill = _read_sprint_skill()
    # 1. Verify base signal pattern exists
    pattern = r"INTERACTIVITY_DEFERRED:\s+brainstorm"
    matches = re.findall(pattern, skill)
    assert len(matches) >= 1, (
        "Sprint SKILL.md must contain at least one INTERACTIVITY_DEFERRED: brainstorm signal "
        "that follows the contract format from replan-observability.md: "
        "'INTERACTIVITY_DEFERRED: brainstorm — <reason>. Re-run sprint interactively to address.'"
    )

    # 2. Verify the contract-required closing phrase appears near the signal
    closing_pattern = r"Re-run sprint interactively to address\."
    closing_matches = re.findall(closing_pattern, skill)
    assert len(closing_matches) >= 1, (
        "Sprint SKILL.md INTERACTIVITY_DEFERRED signal must include the contract-required "
        "closing phrase 'Re-run sprint interactively to address.' per replan-observability.md"
    )

    # 3. Verify the ticket comment CLI format wraps the signal
    cli_pattern = (
        '.claude/scripts/dso ticket comment <epic-id> "INTERACTIVITY_DEFERRED:'
    )
    assert cli_pattern in skill, (
        "Sprint SKILL.md must show the INTERACTIVITY_DEFERRED signal wrapped in the ticket "
        "comment CLI format: .claude/scripts/dso ticket comment <epic-id> "
        '"INTERACTIVITY_DEFERRED: brainstorm — ..."'
    )

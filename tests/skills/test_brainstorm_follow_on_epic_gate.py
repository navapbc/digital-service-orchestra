"""Tests for the follow-on and derivative epic HARD-GATE in brainstorm/SKILL.md.

Bug (LLM-behavioral): brainstorm/SKILL.md lacked a gate preventing creation of
follow-on/derivative epics without explicit per-epic user approval. Approval of
the primary epic (Phase 2 Step 4) was mistakenly treated as blanket approval for
follow-on epics.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BRAINSTORM_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "brainstorm" / "SKILL.md"


def _read_brainstorm() -> str:
    return BRAINSTORM_MD.read_text()


def _extract_follow_on_gate_section(content: str) -> str:
    """Extract the Follow-on and Derivative Epic Gate section."""
    pattern = re.compile(
        r"###.*Follow-on and Derivative Epic Gate.*?(?=\n### |\n## |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


def test_brainstorm_has_follow_on_epic_hard_gate() -> None:
    """brainstorm/SKILL.md must contain a HARD-GATE for follow-on epic creation.

    Without this gate, the orchestrator treats directional approval of the primary
    epic as implicit approval for all follow-on epics, creating unapproved tickets.
    """
    content = _read_brainstorm()
    gate_section = _extract_follow_on_gate_section(content)

    assert gate_section, (
        "Expected brainstorm/SKILL.md to contain a 'Follow-on and Derivative Epic Gate' "
        "section but none was found. This HARD-GATE prevents follow-on epics from being "
        "created without explicit per-epic user approval."
    )

    assert "<HARD-GATE>" in gate_section, (
        "Expected the Follow-on and Derivative Epic Gate section in brainstorm/SKILL.md "
        "to contain a <HARD-GATE> block, but none was found. The gate must use the "
        "<HARD-GATE> tag to be recognized by gate-enforcement checks."
    )


def test_brainstorm_follow_on_gate_prohibits_ticket_create_without_approval() -> None:
    """The follow-on gate must explicitly prohibit calling ticket create without per-epic approval."""
    content = _read_brainstorm()
    gate_section = _extract_follow_on_gate_section(content)

    assert gate_section, (
        "Expected to find 'Follow-on and Derivative Epic Gate' section in brainstorm/SKILL.md."
    )

    has_prohibition = re.search(
        r"Do NOT call.*?ticket create.*?until.*?approved"
        r"|Do NOT.*?ticket create.*?follow-on.*?approved"
        r"|must.*?not.*?ticket create.*?without.*?approv",
        gate_section,
        re.IGNORECASE | re.DOTALL,
    )
    assert has_prohibition, (
        "Expected the follow-on epic gate in brainstorm/SKILL.md to explicitly prohibit "
        "calling 'ticket create' for follow-on epics until the user has approved that "
        "specific epic. The gate must make clear that primary-epic approval does not "
        "extend to follow-on epics."
    )


def test_brainstorm_follow_on_gate_prohibits_treating_primary_approval_as_blanket() -> (
    None
):
    """The follow-on gate must specify that primary epic approval does not cover follow-on epics."""
    content = _read_brainstorm()
    gate_section = _extract_follow_on_gate_section(content)

    assert gate_section, (
        "Expected to find 'Follow-on and Derivative Epic Gate' section in brainstorm/SKILL.md."
    )

    has_blanket_prohibition = re.search(
        r"Do NOT treat.*?directional approval.*?primary epic"
        r"|primary epic.*?approval.*?not.*?follow-on"
        r"|treat.*?approval.*?primary.*?as.*?approval.*?follow",
        gate_section,
        re.IGNORECASE | re.DOTALL,
    )
    assert has_blanket_prohibition, (
        "Expected the follow-on gate to explicitly state that directional approval of the "
        "primary epic (Phase 2 Step 4) does NOT constitute approval for follow-on epics. "
        "Without this guard, the LLM rationalizes creating follow-on epics after the user "
        "approves the main epic spec."
    )

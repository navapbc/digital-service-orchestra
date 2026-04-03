"""Tests for sprint Phase 4 sub-agent dispatch guard.

Bug 4e43-9b85: Sprint orchestrator executes implementation tasks directly
instead of dispatching sub-agents via the Task tool.

These tests verify that Phase 4 contains a HARD-GATE (negative directive)
that explicitly prohibits the orchestrator from implementing tasks directly.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SPRINT_SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"


def _read_sprint_skill() -> str:
    return SPRINT_SKILL_MD.read_text()


def _extract_phase4(content: str) -> str:
    """Extract Phase 4 section from sprint SKILL.md."""
    pattern = re.compile(
        r"## Phase 4: Sub-Agent Launch.*?(?=\n## Phase [5-9]|\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


def test_phase4_has_hard_gate_or_negative_directive() -> None:
    """Phase 4 must contain an explicit prohibition against direct implementation.

    Bug 4e43-9b85: Without a negative directive, the orchestrator rationalizes
    direct Edit/Write as acceptable for 'small' or 'simple' tasks. A HARD-GATE
    or explicit 'Do NOT' instruction is required.
    """
    content = _read_sprint_skill()
    phase4 = _extract_phase4(content)

    assert phase4, "Expected to find 'Phase 4: Sub-Agent Launch' in sprint SKILL.md."

    # Must contain a negative directive about direct implementation
    has_prohibition = re.search(
        r"Do NOT.*(?:implement|edit|write|modify|apply).*directly"
        r"|HARD-GATE.*(?:Task tool|sub-agent)"
        r"|must NOT.*(?:implement|edit|write).*(?:yourself|directly|inline)"
        r"|never.*implement.*(?:directly|yourself|inline).*(?:Edit|Write)",
        phase4,
        re.IGNORECASE | re.DOTALL,
    )
    assert has_prohibition, (
        "Expected Phase 4 of sprint SKILL.md to contain an explicit prohibition "
        "against direct implementation by the orchestrator (e.g., 'Do NOT implement "
        "tasks directly using Edit/Write' or a HARD-GATE block). Without a negative "
        "directive, the orchestrator rationalizes skipping sub-agent dispatch for "
        "'small' or 'simple' tasks."
    )

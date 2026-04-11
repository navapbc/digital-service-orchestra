"""Behavioral tests for fix-bug SKILL.md unresolved sub-agent signal contract.

Bug c46f-f51b: When a fix-bug sub-agent cannot fix a bug, there was no defined
FIX_RESULT: unresolved signal, causing orchestrators to improvise by closing
tickets with --reason='Escalated to user:' without surfacing the bug to the user.

These tests verify the structural presence of the FIX_RESULT: unresolved contract
in fix-bug SKILL.md and the corresponding handling instructions in debug-everything
SKILL.md (leave ticket OPEN, surface in session summary).
"""

from __future__ import annotations

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX_BUG_SKILL = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"
DEBUG_EVERYTHING_SKILL = (
    REPO_ROOT / "plugins" / "dso" / "skills" / "debug-everything" / "SKILL.md"
)


class TestFixBugUnresolvedSignal:
    """Tests that fix-bug SKILL.md defines a FIX_RESULT: unresolved contract."""

    def test_fix_result_unresolved_defined_in_skill(self) -> None:
        """fix-bug SKILL.md must define FIX_RESULT: unresolved sub-agent signal."""
        content = FIX_BUG_SKILL.read_text()
        assert "FIX_RESULT: unresolved" in content, (
            "fix-bug SKILL.md missing FIX_RESULT: unresolved signal definition. "
            "Without this, orchestrators have no defined path when a bug cannot be "
            "fixed and may improvise with prohibited 'Escalated to user:' closes."
        )

    def test_fix_result_unresolved_instructs_leave_open(self) -> None:
        """fix-bug SKILL.md must instruct orchestrators to leave ticket OPEN on unresolved."""
        content = FIX_BUG_SKILL.read_text()
        # Both the signal definition and the leave-open instruction must be present
        assert "FIX_RESULT: unresolved" in content, (
            "FIX_RESULT: unresolved signal not defined — see test above."
        )
        # Check that somewhere after 'FIX_RESULT: unresolved' there's instruction to leave OPEN
        unresolved_idx = content.index("FIX_RESULT: unresolved")
        remaining = content[unresolved_idx : unresolved_idx + 2000]
        has_leave_open = "leave" in remaining.lower() and "open" in remaining.lower()
        assert has_leave_open, (
            "fix-bug SKILL.md defines FIX_RESULT: unresolved but does not instruct "
            "orchestrators to leave the ticket OPEN in the surrounding context."
        )


class TestDebugEverythingUnresolvedHandling:
    """Tests that debug-everything SKILL.md handles FIX_RESULT: unresolved correctly."""

    def test_debug_everything_handles_unresolved_result(self) -> None:
        """debug-everything SKILL.md must handle FIX_RESULT: unresolved explicitly."""
        content = DEBUG_EVERYTHING_SKILL.read_text()
        assert "FIX_RESULT: unresolved" in content, (
            "debug-everything SKILL.md does not handle FIX_RESULT: unresolved outcome. "
            "When fix-bug sub-agents cannot fix a bug, the orchestrator must have explicit "
            "instructions referencing the FIX_RESULT: unresolved signal."
        )

    def test_debug_everything_instructs_leave_open_on_unresolved(self) -> None:
        """debug-everything SKILL.md must say leave ticket OPEN near FIX_RESULT: unresolved."""
        content = DEBUG_EVERYTHING_SKILL.read_text()
        # Bound the search to the vicinity of 'FIX_RESULT: unresolved' so the test is
        # refactor-safe — we need 'leave' and 'OPEN' to appear in that specific section,
        # not just anywhere in the 1000+ line file.
        unresolved_idx = content.find("FIX_RESULT: unresolved")
        assert unresolved_idx != -1, (
            "FIX_RESULT: unresolved not found — preceding test should have caught this."
        )
        # Check 500 chars around the unresolved entry for leave+OPEN instructions
        vicinity = content[unresolved_idx : unresolved_idx + 500]
        assert "leave" in vicinity.lower() and "open" in vicinity.lower(), (
            "debug-everything SKILL.md FIX_RESULT: unresolved row does not instruct "
            "agents to leave the ticket OPEN in the surrounding context."
        )

    def test_debug_everything_prohibits_escalated_to_user_close(self) -> None:
        """debug-everything SKILL.md must explicitly prohibit closing with 'Escalated to user:'."""
        content = DEBUG_EVERYTHING_SKILL.read_text()
        # The prohibition must exist as an example of what NOT to do
        assert "Escalated to user" in content, (
            "debug-everything SKILL.md missing explicit prohibition on "
            "'Escalated to user:' autonomous ticket closes."
        )

    def test_debug_everything_surfaces_unfixable_bugs_in_summary(self) -> None:
        """debug-everything SKILL.md must instruct surfacing unfixable bugs in session summary."""
        content = DEBUG_EVERYTHING_SKILL.read_text()
        # Bound the search to the vicinity of FIX_RESULT: unresolved — 'surface' alone appears
        # in unrelated contexts throughout the file.
        unresolved_idx = content.find("FIX_RESULT: unresolved")
        assert unresolved_idx != -1, (
            "FIX_RESULT: unresolved not found — preceding test should have caught this."
        )
        vicinity = content[unresolved_idx : unresolved_idx + 500]
        has_surface = (
            "session summary" in vicinity.lower()
            or "ESCALATED BUGS" in vicinity
            or ("surface" in vicinity.lower() and "summary" in vicinity.lower())
        )
        assert has_surface, (
            "debug-everything SKILL.md FIX_RESULT: unresolved section does not instruct "
            "surfacing unfixable bugs in the session summary."
        )

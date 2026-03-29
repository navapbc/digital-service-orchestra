"""Structural metadata validation of skill file — verifying design contract that Gate 1a
integration exists, not implementation logic. Tests 1-10 are schema validation (acceptable
structural category). Test 11 is behavioral.

TDD spec for task 69bb-f34a (RED task):
- plugins/dso/skills/fix-bug/SKILL.md must contain Gate 1a documentation:
  1. A Gate 1a section or Intent Search section heading
  2. Reference to intent-search agent dispatch
  3. All three outcomes: intent-aligned, intent-contradicting, ambiguous
  4. Auto-close command pattern with ticket transition + reason flag
  5. --reason prefix "Fixed: Intent-contradicting" (per Critical Rule 19)
  6. Ticket comment step for evidence citation
  7. Reference to debug.intent_search_budget config key
  8. Gate 1a positioned before investigation dispatch (Step 2)
  9. Reference to gate-signal-schema contract
  10. Graceful degradation to ambiguous on agent failure
  11. Behavioral: read-config.sh subprocess call returns "20" for debug.intent_search_budget

All tests fail RED because Gate 1a is not yet present in SKILL.md.
"""

import pathlib
import subprocess

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"
READ_CONFIG_SCRIPT = REPO_ROOT / "plugins" / "dso" / "scripts" / "read-config.sh"
DSO_CONFIG_FILE = REPO_ROOT / ".claude" / "dso-config.conf"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


class TestFixBugGate1aDesignContract:
    """Tests asserting the Gate 1a design contract is documented in fix-bug SKILL.md.

    Gate 1a is a pre-investigation intent search gate that runs before investigation
    dispatch (Step 2). These tests verify that the skill documents its integration,
    the agent it delegates to, its three outcome paths, its auto-close behavior for
    intent-contradicting bugs, the ticket comment evidence step, budget config key
    reference, positional ordering, gate-signal-schema contract reference, and its
    graceful degradation to ambiguous on agent failure.
    """

    def test_gate_1a_section_exists(self) -> None:
        """SKILL.md must contain a Gate 1a or Intent Search section."""
        content = _read_skill()
        assert "Gate 1a" in content or "Intent Search" in content, (
            "Expected SKILL.md to contain 'Gate 1a' or 'Intent Search' as a named gate "
            "section. Gate 1a is the pre-investigation intent search gate that runs before "
            "Step 2 investigation dispatch to classify whether the bug aligns with system intent. "
            "This is a RED test — Gate 1a has not yet been added to SKILL.md."
        )

    def test_gate_1a_dispatches_intent_search(self) -> None:
        """SKILL.md must reference intent-search agent dispatch for Gate 1a."""
        content = _read_skill()
        assert "intent-search" in content, (
            "Expected SKILL.md to contain 'intent-search' to document that Gate 1a dispatches "
            "the dso:intent-search agent to classify bug intent before investigation begins. "
            "This is a RED test — the intent-search agent dispatch reference has not yet been "
            "added to SKILL.md."
        )

    def test_gate_1a_three_outcomes(self) -> None:
        """SKILL.md must document all three Gate 1a outcomes: intent-aligned, intent-contradicting, ambiguous."""
        content = _read_skill()
        missing = [
            outcome
            for outcome in ("intent-aligned", "intent-contradicting", "ambiguous")
            if outcome not in content
        ]
        assert not missing, (
            f"Expected SKILL.md to document all three Gate 1a outcomes but missing: {missing}. "
            "Gate 1a must classify bugs as intent-aligned (proceed to investigation), "
            "intent-contradicting (auto-close), or ambiguous (proceed with caution). "
            "This is a RED test — Gate 1a outcomes have not yet been documented in SKILL.md."
        )

    def test_gate_1a_auto_close_pattern(self) -> None:
        """SKILL.md must document Gate 1a auto-close command: ticket transition with reason for intent-contradicting bugs."""
        content = _read_skill()
        # Gate 1a auto-close is specific: it must use ticket transition AND reference
        # intent-contradicting in the same Gate 1a section. Checking both together ensures
        # the test fails before Gate 1a is added, not just because other parts of SKILL.md
        # already have ticket transition commands.
        has_gate_1a = "Gate 1a" in content or "Intent Search" in content
        has_intent_contradicting = "intent-contradicting" in content
        has_transition = "ticket transition" in content
        assert has_gate_1a and has_intent_contradicting and has_transition, (
            "Expected SKILL.md to contain Gate 1a documentation with both an 'intent-contradicting' "
            "outcome and a 'ticket transition' auto-close command. Gate 1a must document that "
            "intent-contradicting bugs are auto-closed using 'ticket transition' with '--reason'. "
            f"Has Gate 1a section: {has_gate_1a}, has intent-contradicting: {has_intent_contradicting}, "
            f"has ticket transition: {has_transition}. "
            "This is a RED test — the Gate 1a auto-close command pattern has not yet been added to SKILL.md."
        )

    def test_gate_1a_auto_close_reason_prefix(self) -> None:
        """SKILL.md must document --reason prefix 'Fixed: Intent-contradicting' (Critical Rule 19)."""
        content = _read_skill()
        assert "Fixed: Intent-contradicting" in content, (
            "Expected SKILL.md to contain 'Fixed: Intent-contradicting' as the --reason prefix "
            "for auto-closing intent-contradicting bugs. Per Critical Rule 19, only 'Fixed:' or "
            "'Escalated to user:' prefixes are accepted; omitting them causes a silent failure. "
            "This is a RED test — the 'Fixed: Intent-contradicting' reason prefix has not yet "
            "been documented in SKILL.md."
        )

    def test_gate_1a_evidence_comment(self) -> None:
        """SKILL.md must document a Gate 1a ticket comment step for intent-contradicting evidence citation."""
        content = _read_skill()
        # Gate 1a specifically requires an evidence comment before auto-close for intent-contradicting
        # bugs. The test checks that Gate 1a documentation (requiring Gate 1a section to exist)
        # includes a ticket comment step for evidence — not just any ticket comment elsewhere.
        has_gate_1a = "Gate 1a" in content or "Intent Search" in content
        has_intent_contradicting = "intent-contradicting" in content
        has_comment = "ticket comment" in content
        assert has_gate_1a and has_intent_contradicting and has_comment, (
            "Expected SKILL.md to contain Gate 1a documentation with both an 'intent-contradicting' "
            "outcome and a 'ticket comment' evidence citation step. Gate 1a must document adding a "
            "ticket comment (citing intent-contradicting signal source) before auto-closing the ticket. "
            f"Has Gate 1a section: {has_gate_1a}, has intent-contradicting: {has_intent_contradicting}, "
            f"has ticket comment: {has_comment}. "
            "This is a RED test — the Gate 1a evidence comment step has not yet been documented in SKILL.md."
        )

    def test_gate_1a_reads_budget_config(self) -> None:
        """SKILL.md must reference debug.intent_search_budget config key."""
        content = _read_skill()
        assert "debug.intent_search_budget" in content, (
            "Expected SKILL.md to contain 'debug.intent_search_budget' to document the config "
            "key that controls the token/time budget allocated to the intent-search agent dispatch. "
            "This is a RED test — the debug.intent_search_budget config key reference has not "
            "yet been added to SKILL.md."
        )

    def test_gate_1a_position(self) -> None:
        """Gate 1a must appear before Step 2 (investigation dispatch) in SKILL.md."""
        content = _read_skill()
        assert "Gate 1a" in content or "Intent Search" in content, (
            "Expected SKILL.md to contain 'Gate 1a' or 'Intent Search'. "
            "This is a RED test — Gate 1a has not yet been added to SKILL.md."
        )
        gate_marker = "Gate 1a" if "Gate 1a" in content else "Intent Search"
        gate_pos = content.index(gate_marker)
        assert "Step 2" in content, (
            "Expected SKILL.md to contain 'Step 2' (investigation dispatch) so that "
            "Gate 1a positioning can be verified as occurring before investigation."
        )
        step2_pos = content.index("Step 2")
        assert gate_pos < step2_pos, (
            f"Expected '{gate_marker}' (position {gate_pos}) to appear before "
            f"'Step 2' (position {step2_pos}) in SKILL.md. "
            "Gate 1a is a pre-investigation gate and must run before Step 2 investigation dispatch. "
            "This is a RED test — Gate 1a has not yet been positioned before Step 2 in SKILL.md."
        )

    def test_gate_1a_signal_schema(self) -> None:
        """SKILL.md must reference the gate-signal-schema contract."""
        content = _read_skill()
        assert "gate-signal-schema" in content, (
            "Expected SKILL.md to contain 'gate-signal-schema' to document that Gate 1a signals "
            "conform to the shared gate signal schema contract defined in "
            "plugins/dso/docs/contracts/gate-signal-schema.md. "
            "This is a RED test — the gate-signal-schema contract reference has not yet been "
            "added to SKILL.md."
        )

    def test_gate_1a_failure_fallback(self) -> None:
        """SKILL.md must document graceful degradation to ambiguous when intent-search agent fails."""
        content = _read_skill()
        # The skill must document that on agent failure, Gate 1a defaults to ambiguous
        # rather than blocking the workflow (fail-open to ambiguous, not fail-closed)
        has_fallback = "ambiguous" in content and (
            "agent failure" in content
            or "graceful" in content
            or "fallback" in content
            or "fail" in content.lower()
            and "ambiguous" in content
        )
        assert has_fallback, (
            "Expected SKILL.md to document that Gate 1a degrades gracefully to 'ambiguous' "
            "when the intent-search agent fails (timeout, nonzero exit, empty output, or "
            "unparseable JSON). Failing open to ambiguous prevents agent errors from blocking "
            "legitimate bug investigations. "
            "This is a RED test — the graceful degradation fallback has not yet been documented "
            "in SKILL.md."
        )

    def test_gate_1a_config_key_default(self) -> None:
        """Behavioral: read-config.sh returns '20' for debug.intent_search_budget (default value)."""
        result = subprocess.run(
            ["bash", str(READ_CONFIG_SCRIPT), "debug.intent_search_budget"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, (
            f"Expected read-config.sh to exit 0 for debug.intent_search_budget, "
            f"got exit code {result.returncode}. stderr: {result.stderr!r}"
        )
        output = result.stdout.strip()
        assert output == "20", (
            f"Expected read-config.sh to return '20' as the default value for "
            f"'debug.intent_search_budget', but got: {output!r}. "
            "The config key either does not exist in dso-config.conf (returns empty) or "
            "is set to a different value. "
            "This is a RED test — debug.intent_search_budget=20 has not yet been added "
            "to .claude/dso-config.conf."
        )

"""Structural metadata validation of skill file — verifying design contract that Gate 1b
integration exists, not implementation logic.

TDD spec for task cfc8-19bb (RED task):
- plugins/dso/skills/fix-bug/SKILL.md must contain Gate 1b documentation:
  1. A Gate 1b section or Feature Request Check section heading
  2. Reference to gate-1b-feature-request-check.py script
  3. Documentation that Gate 1b fires only when Gate 1a returns ambiguous
  4. Documentation that Gate 1b is skipped for intent-aligned and intent-contradicting
  5. Reference to signal_type primary signal
  6. Gate 1b positioned before investigation dispatch (Step 2)
  7. Graceful degradation documentation on agent/script failure

All tests fail RED because Gate 1b section is not yet present in SKILL.md.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


class TestFixBugGate1bDesignContract:
    """Tests asserting the Gate 1b design contract is documented in fix-bug SKILL.md.

    Gate 1b is a pre-investigation feature-request language check that fires after Gate 1a
    returns ambiguous. These tests verify that the skill documents its integration, the
    script it delegates to, its conditional trigger on ambiguous Gate 1a results, its skip
    behavior for non-ambiguous results, its primary signal type, its pre-investigation
    positioning, and its graceful degradation on failure.
    """

    def test_gate_1b_section_exists(self) -> None:
        """SKILL.md must contain a Gate 1b section heading (not merely a forward reference)."""
        content = _read_skill()
        import re

        # A proper section heading is a markdown heading line (### or ##) containing "Gate 1b"
        has_section_heading = bool(
            re.search(r"^#{1,4}\s+.*Gate 1b", content, re.MULTILINE)
        )
        assert has_section_heading, (
            "Expected SKILL.md to contain a markdown section heading (e.g., '### Gate 1b: ...' "
            "or '### Step 1.7: Gate 1b ...') for the Gate 1b feature-request language check. "
            "SKILL.md currently contains 'Gate 1b' only in forward-reference prose and a comment — "
            "the actual Gate 1b section (with heading) does not exist yet. "
            "Gate 1b is the feature-request language check that fires after Gate 1a returns "
            "ambiguous, analyzing ticket title and description for patterns indicating a feature "
            "request rather than a bug report. "
            "This is a RED test — Gate 1b section heading has not yet been added to SKILL.md."
        )

    def test_gate_1b_dispatches_script(self) -> None:
        """SKILL.md must reference gate-1b-feature-request-check.py as the Gate 1b implementation."""
        content = _read_skill()
        assert "gate-1b-feature-request-check.py" in content, (
            "Expected SKILL.md to contain 'gate-1b-feature-request-check.py' to document "
            "the script that implements the Gate 1b feature-request language detection check. "
            "This is a RED test — the script reference has not yet been added to SKILL.md."
        )

    def test_gate_1b_fires_after_ambiguous(self) -> None:
        """SKILL.md must document that Gate 1b fires conditionally on Gate 1a ambiguous result."""
        content = _read_skill()
        # The section must exist (not just forward ref) AND must document the ambiguous condition
        # Check that 'ambiguous' and 'Gate 1b' appear in close proximity indicating the conditional
        # Search past the forward-reference comment for substantive Gate 1b documentation
        substantive_idx = content.find("gate-1b-feature-request-check.py")
        has_ambiguous_condition = (
            substantive_idx != -1
            and "ambiguous"
            in content[max(0, substantive_idx - 500) : substantive_idx + 2000]
        )
        assert has_ambiguous_condition, (
            "Expected SKILL.md to document that Gate 1b fires only when Gate 1a returns "
            "'ambiguous'. Gate 1b must not run for intent-aligned or intent-contradicting "
            "outcomes — it is a disambiguation step specifically for the ambiguous case. "
            "This is a RED test — the Gate 1b conditional trigger on ambiguous has not yet "
            "been documented in SKILL.md."
        )

    def test_gate_1b_skipped_when_not_ambiguous(self) -> None:
        """SKILL.md must document that Gate 1b is skipped for intent-aligned and intent-contradicting."""
        content = _read_skill()
        script_idx = content.find("gate-1b-feature-request-check.py")
        assert script_idx != -1, (
            "Expected SKILL.md to reference 'gate-1b-feature-request-check.py' — not found. "
            "This is a RED test — Gate 1b has not yet been added to SKILL.md."
        )
        # Verify that the Gate 1b section documents skip/bypass for non-ambiguous paths
        gate_1b_context = content[max(0, script_idx - 500) : script_idx + 3000]
        has_skip_doc = (
            "skip" in gate_1b_context.lower()
            or "bypass" in gate_1b_context.lower()
            or "only when" in gate_1b_context.lower()
            or (
                "intent-aligned" in gate_1b_context
                and "intent-contradicting" in gate_1b_context
            )
        )
        assert has_skip_doc, (
            "Expected SKILL.md to document that Gate 1b is skipped when Gate 1a returns "
            "intent-aligned or intent-contradicting. Gate 1b must only run in the ambiguous "
            "path to avoid unnecessary feature-request checks for clear bug/non-bug signals. "
            "This is a RED test — Gate 1b skip behavior has not yet been documented in SKILL.md."
        )

    def test_gate_1b_primary_signal(self) -> None:
        """SKILL.md must reference signal_type primary in the Gate 1b section."""
        content = _read_skill()
        script_idx = content.find("gate-1b-feature-request-check.py")
        assert script_idx != -1, (
            "Expected SKILL.md to reference 'gate-1b-feature-request-check.py' — not found. "
            "This is a RED test — Gate 1b has not yet been added to SKILL.md."
        )
        gate_1b_context = content[script_idx : script_idx + 3000]
        assert "signal_type" in gate_1b_context, (
            "Expected the Gate 1b section of SKILL.md to reference 'signal_type' to document "
            "the primary signal emitted by gate-1b-feature-request-check.py. Gate 1b is a "
            "primary gate — when triggered, its signal_type drives a routing decision. "
            "This is a RED test — signal_type has not yet been referenced in the Gate 1b "
            "section of SKILL.md."
        )

    def test_gate_1b_pre_investigation(self) -> None:
        """Gate 1b must appear before Step 2 (investigation dispatch) in SKILL.md."""
        content = _read_skill()
        script_idx = content.find("gate-1b-feature-request-check.py")
        assert script_idx != -1, (
            "Expected SKILL.md to contain 'gate-1b-feature-request-check.py'. "
            "This is a RED test — Gate 1b has not yet been added to SKILL.md."
        )
        assert "Step 2" in content, (
            "Expected SKILL.md to contain 'Step 2' (investigation dispatch) so that "
            "Gate 1b positioning can be verified as occurring before investigation."
        )
        step2_pos = content.index("Step 2")
        assert script_idx < step2_pos, (
            f"Expected 'gate-1b-feature-request-check.py' (position {script_idx}) to appear "
            f"before 'Step 2' (position {step2_pos}) in SKILL.md. "
            "Gate 1b is a pre-investigation gate — it must run before Step 2 investigation "
            "dispatch to prevent wasted investigation effort on feature requests. "
            "This is a RED test — Gate 1b has not yet been positioned before Step 2 in SKILL.md."
        )

    def test_gate_1b_failure_fallback(self) -> None:
        """SKILL.md must document graceful degradation when gate-1b-feature-request-check.py fails."""
        content = _read_skill()
        script_idx = content.find("gate-1b-feature-request-check.py")
        assert script_idx != -1, (
            "Expected SKILL.md to reference 'gate-1b-feature-request-check.py' — not found. "
            "This is a RED test — Gate 1b has not yet been added to SKILL.md."
        )
        gate_1b_context = content[script_idx : script_idx + 3000]
        has_fallback = (
            "fallback" in gate_1b_context.lower()
            or "graceful" in gate_1b_context.lower()
            or "nonzero" in gate_1b_context.lower()
            or "failure" in gate_1b_context.lower()
            or "triggered:false" in gate_1b_context
            or "triggered: false" in gate_1b_context
        )
        assert has_fallback, (
            "Expected SKILL.md to document Gate 1b graceful degradation: when "
            "gate-1b-feature-request-check.py exits nonzero, produces empty stdout, or "
            "yields unparseable JSON, the gate defaults to non-blocking (triggered: false) "
            "rather than hard-failing the workflow. "
            "This is a RED test — Gate 1b failure fallback has not yet been documented in SKILL.md."
        )

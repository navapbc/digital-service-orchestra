"""Structural metadata validation of skill file — design contract verification.

TDD spec for task 744c-6916 (RED task):
- plugins/dso/skills/fix-bug/SKILL.md must contain Gate 2b documentation:
  1. A Gate 2b section heading
  2. Reference to the gate-2b-blast-radius.sh script
  3. Documentation that Gate 2b is a modifier only, never adds primary signal
  4. Gate 2b positioned after investigation/fix proposal
  5. Documentation of annotation appended to escalation dialog context
  6. Documentation of graceful degradation (skip annotation silently on error)
  7. Documentation of grep fallback when ast-grep is unavailable

All tests fail RED because Gate 2b is not yet present in SKILL.md.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


class TestFixBugGate2bDesignContract:
    """Tests asserting the Gate 2b design contract is documented in fix-bug SKILL.md.

    Gate 2b is a post-investigation blast-radius annotation gate that runs after
    fix proposal. Unlike Gate 2a, it is a modifier only — it enriches the
    escalation dialog context with blast-radius information but never adds a
    primary blocking signal. These tests verify that the skill documents its
    integration, the script it delegates to, its modifier-only role, its
    positioning in the workflow, its annotation behavior, its failure fallback,
    and its ast-grep/grep fallback strategy.
    """

    def test_gate_2b_section_exists(self) -> None:
        """SKILL.md must contain a Gate 2b section."""
        content = _read_skill()
        assert "Gate 2b" in content, (
            "Expected SKILL.md to contain 'Gate 2b' as a named gate section. "
            "Gate 2b is the post-investigation blast-radius annotation gate that "
            "runs after fix proposal to enrich escalation dialog context. "
            "This is a RED test — Gate 2b has not yet been added to SKILL.md."
        )

    def test_gate_2b_dispatches_script(self) -> None:
        """SKILL.md must reference gate-2b-blast-radius.sh as the Gate 2b implementation."""
        content = _read_skill()
        assert "gate-2b-blast-radius.sh" in content, (
            "Expected SKILL.md to contain 'gate-2b-blast-radius.sh' to document "
            "the script that implements the Gate 2b blast-radius annotation. "
            "This is a RED test — the script reference has not yet been added to SKILL.md."
        )

    def test_gate_2b_modifier_only(self) -> None:
        """SKILL.md must document that Gate 2b is a modifier only and never adds primary signal."""
        content = _read_skill()
        # The assertion requires both "Gate 2b" and "modifier" to appear in close proximity,
        # meaning the modifier-only contract is documented in the Gate 2b section specifically.
        # A loose search for "modifier" alone would match "Bonus Modifiers" — require co-occurrence.
        gate_2b_present = "Gate 2b" in content
        modifier_near_gate = gate_2b_present and (
            "modifier"
            in content[content.index("Gate 2b") : content.index("Gate 2b") + 500]
            if gate_2b_present
            else False
        )
        assert modifier_near_gate, (
            "Expected SKILL.md to contain 'modifier' within the Gate 2b section to document "
            "that Gate 2b acts only as a modifier — it annotates the escalation dialog context "
            "with blast-radius information but never adds a primary blocking signal "
            "that could halt the fix workflow on its own. "
            "This is a RED test — the modifier-only contract has not yet been documented in SKILL.md."
        )

    def test_gate_2b_post_investigation(self) -> None:
        """Gate 2b must appear after investigation/fix proposal in SKILL.md."""
        content = _read_skill()
        assert "Gate 2b" in content, (
            "Expected SKILL.md to contain 'Gate 2b'. "
            "This is a RED test — Gate 2b has not yet been added to SKILL.md."
        )
        gate_2b_pos = content.index("Gate 2b")
        # Step 5 (RED test writing / fix proposal) must precede Gate 2b
        assert "Step 5" in content, (
            "Expected SKILL.md to contain 'Step 5' so that Gate 2b positioning "
            "can be verified as appearing after the fix investigation/proposal phase."
        )
        step5_pos = content.index("Step 5")
        assert step5_pos < gate_2b_pos, (
            f"Expected 'Step 5' (position {step5_pos}) to appear before "
            f"'Gate 2b' (position {gate_2b_pos}) in SKILL.md. "
            "Gate 2b must run after the fix investigation/proposal step. "
            "This is a RED test — Gate 2b has not yet been positioned in SKILL.md."
        )

    def test_gate_2b_annotation_in_dialog(self) -> None:
        """SKILL.md must document that Gate 2b annotation is appended to escalation dialog context."""
        content = _read_skill()
        # Require co-occurrence of "Gate 2b" and "annotation" in the same section so the test
        # doesn't pass due to unrelated "type annotation" references already in the file.
        gate_2b_present = "Gate 2b" in content
        annotation_near_gate = gate_2b_present and (
            "annotation"
            in content[content.index("Gate 2b") : content.index("Gate 2b") + 600]
            if gate_2b_present
            else False
        )
        assert annotation_near_gate, (
            "Expected SKILL.md to contain 'annotation' within the Gate 2b section to document "
            "that Gate 2b appends blast-radius information to the escalation dialog context, "
            "making the annotation visible to the escalation handler rather than "
            "acting as a standalone blocking signal. "
            "This is a RED test — the annotation behavior has not yet been documented in SKILL.md."
        )

    def test_gate_2b_failure_fallback(self) -> None:
        """SKILL.md must document graceful degradation when gate-2b-blast-radius.sh fails."""
        content = _read_skill()
        # Require co-occurrence of "Gate 2b" and a graceful-skip token within the Gate 2b section.
        # A loose "silently"/"skip" search would match unrelated workflow steps already present.
        gate_2b_present = "Gate 2b" in content
        if not gate_2b_present:
            assert False, (
                "Expected SKILL.md to contain 'Gate 2b'. "
                "This is a RED test — Gate 2b has not yet been added to SKILL.md."
            )
        gate_2b_section = content[
            content.index("Gate 2b") : content.index("Gate 2b") + 700
        ]
        fallback_documented = "silently" in gate_2b_section or (
            "skip" in gate_2b_section and "annotation" in gate_2b_section
        )
        assert fallback_documented, (
            "Expected SKILL.md to document within the Gate 2b section that on error "
            "(nonzero exit, empty output, or parse failure from gate-2b-blast-radius.sh), "
            "the annotation step is skipped silently rather than hard-failing the fix workflow. "
            "This is a RED test — the failure fallback behavior has not yet been documented in SKILL.md."
        )

    def test_gate_2b_ast_grep_fallback(self) -> None:
        """SKILL.md must document that gate-2b-blast-radius.sh falls back to grep when ast-grep is unavailable."""
        content = _read_skill()
        assert "ast-grep" in content, (
            "Expected SKILL.md to contain 'ast-grep' to document the fallback strategy "
            "in gate-2b-blast-radius.sh: when ast-grep is not available in the environment, "
            "the script falls back to standard grep for blast-radius analysis so the gate "
            "remains functional across environments. "
            "This is a RED test — the ast-grep fallback has not yet been documented in SKILL.md."
        )

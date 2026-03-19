"""Tests for content requirements of the fix-bug skill file.

TDD spec for task dso-k0yk (RED task):
- plugins/dso/skills/fix-bug/SKILL.md must exist and contain:
  1. Frontmatter with 'name: fix-bug'
  2. 'user-invocable: true' in frontmatter
  3. Mechanical classification language ('mechanical', 'import error', 'lint violation')
  4. Severity scoring rubric language
  5. Complexity scoring rubric language
  6. Environment scoring rubric language
  7. Routing thresholds ('BASIC', 'INTERMEDIATE', 'ADVANCED') with threshold values
  8. RESULT report schema fields ('ROOT_CAUSE', 'confidence')
  9. Discovery file protocol reference
  10. Hypothesis testing phase reference
  11. TDD workflow config pattern (read-config.sh)
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


def test_fix_bug_skill_file_exists() -> None:
    """The fix-bug SKILL.md file must exist at the expected path."""
    assert SKILL_FILE.exists(), (
        f"Expected fix-bug skill file to exist at {SKILL_FILE}. "
        "This is a RED test — the file does not exist yet and must be created."
    )


def test_fix_bug_skill_frontmatter_name() -> None:
    """SKILL.md must declare 'name: fix-bug' in its frontmatter."""
    content = _read_skill()
    assert "name: fix-bug" in content, (
        "Expected SKILL.md to contain 'name: fix-bug' in the frontmatter "
        "to register the skill under its canonical invocation name."
    )


def test_fix_bug_skill_user_invocable() -> None:
    """SKILL.md must declare 'user-invocable: true' in its frontmatter."""
    content = _read_skill()
    assert "user-invocable: true" in content, (
        "Expected SKILL.md to contain 'user-invocable: true' so the skill "
        "is exposed as a directly invocable command for DSO practitioners."
    )


def test_fix_bug_skill_mechanical_classification() -> None:
    """SKILL.md must define mechanical bug classification with example types."""
    content = _read_skill()
    assert "mechanical" in content, (
        "Expected SKILL.md to contain 'mechanical' to name the simplest "
        "category of bugs that require no deep investigation."
    )
    assert "import error" in content, (
        "Expected SKILL.md to contain 'import error' as an example of a "
        "mechanical bug type in the classification section."
    )
    assert "lint violation" in content, (
        "Expected SKILL.md to contain 'lint violation' as an example of a "
        "mechanical bug type in the classification section."
    )


def test_fix_bug_skill_scoring_rubric_severity() -> None:
    """SKILL.md must contain severity scoring language in the rubric."""
    content = _read_skill()
    assert "severity" in content, (
        "Expected SKILL.md to contain 'severity' as a scoring dimension "
        "in the bug classification rubric."
    )


def test_fix_bug_skill_scoring_rubric_complexity() -> None:
    """SKILL.md must contain complexity scoring language in the rubric."""
    content = _read_skill()
    assert "complexity" in content, (
        "Expected SKILL.md to contain 'complexity' as a scoring dimension "
        "in the bug classification rubric."
    )


def test_fix_bug_skill_scoring_rubric_environment() -> None:
    """SKILL.md must contain environment scoring language in the rubric."""
    content = _read_skill()
    assert "environment" in content, (
        "Expected SKILL.md to contain 'environment' as a scoring dimension "
        "in the bug classification rubric (e.g., reproducibility context)."
    )


def test_fix_bug_skill_routing_thresholds() -> None:
    """SKILL.md must define BASIC, INTERMEDIATE, and ADVANCED routing tiers with thresholds."""
    content = _read_skill()
    assert "BASIC" in content, (
        "Expected SKILL.md to contain 'BASIC' as the lowest routing tier "
        "for straightforward bugs."
    )
    assert "INTERMEDIATE" in content, (
        "Expected SKILL.md to contain 'INTERMEDIATE' as the mid-tier routing "
        "category for moderately complex bugs."
    )
    assert "ADVANCED" in content, (
        "Expected SKILL.md to contain 'ADVANCED' as the highest routing tier "
        "for complex bugs requiring deep investigation."
    )


def test_fix_bug_skill_result_schema() -> None:
    """SKILL.md must define a RESULT report schema containing ROOT_CAUSE and confidence."""
    content = _read_skill()
    assert "ROOT_CAUSE" in content, (
        "Expected SKILL.md to contain 'ROOT_CAUSE' as a required field "
        "in the RESULT report schema output."
    )
    assert "confidence" in content, (
        "Expected SKILL.md to contain 'confidence' as a required field "
        "in the RESULT report schema output."
    )


def test_fix_bug_skill_discovery_file_protocol() -> None:
    """SKILL.md must reference the discovery file protocol for captured findings."""
    content = _read_skill()
    assert "discovery file" in content, (
        "Expected SKILL.md to contain 'discovery file' to describe the protocol "
        "for writing structured bug investigation findings to a shared artifact."
    )


def test_fix_bug_skill_hypothesis_testing_phase() -> None:
    """SKILL.md must include a hypothesis testing phase in the investigation workflow."""
    content = _read_skill()
    assert "hypothesis" in content, (
        "Expected SKILL.md to contain 'hypothesis' to describe the phase where "
        "the agent proposes and tests a root-cause theory before implementing a fix."
    )


def test_fix_bug_skill_tdd_workflow_config_pattern() -> None:
    """SKILL.md must reference read-config.sh for config resolution."""
    content = _read_skill()
    assert "read-config.sh" in content, (
        "Expected SKILL.md to contain 'read-config.sh' as the canonical way "
        "to resolve workflow configuration values (TDD workflow config pattern)."
    )


class TestBasicInvestigationSkillIntegration:
    """Tests asserting the BASIC investigation section of SKILL.md references
    the prompt template file and includes explicit context-assembly instructions.

    TDD spec for task w21-8yqq (RED task):
    - plugins/dso/skills/fix-bug/SKILL.md BASIC section must:
      1. Reference 'basic-investigation.md' prompt template file
      2. Use 'prompts/' directory convention
      3. Define explicit context-assembly slots (failing_tests, stack_trace, commit_history)
      4. Reference RESULT format conformance for the sub-agent output schema
    """

    def test_basic_section_references_prompt_template_file(self) -> None:
        """SKILL.md BASIC section must reference the 'basic-investigation.md' prompt template."""
        content = _read_skill()
        assert "basic-investigation.md" in content, (
            "Expected SKILL.md to contain 'basic-investigation.md' to reference "
            "the prompt template file for the BASIC investigation dispatch. "
            "This is a RED test — SKILL.md does not yet reference this file."
        )

    def test_basic_section_uses_prompts_directory_convention(self) -> None:
        """SKILL.md BASIC section must use the 'prompts/' directory convention."""
        content = _read_skill()
        assert "prompts/" in content, (
            "Expected SKILL.md to contain 'prompts/' to follow the standard "
            "prompts directory convention for referencing prompt template files. "
            "This is a RED test — SKILL.md does not yet use this convention."
        )

    def test_basic_section_defines_context_assembly_slots(self) -> None:
        """SKILL.md BASIC section must define named context slots for the dispatch."""
        content = _read_skill()
        assert "failing_tests" in content, (
            "Expected SKILL.md to contain 'failing_tests' as a named context slot "
            "in the BASIC dispatch assembly instructions. "
            "This is a RED test — SKILL.md does not yet define these context slots."
        )
        assert "stack_trace" in content, (
            "Expected SKILL.md to contain 'stack_trace' as a named context slot "
            "in the BASIC dispatch assembly instructions."
        )
        assert "commit_history" in content, (
            "Expected SKILL.md to contain 'commit_history' as a named context slot "
            "in the BASIC dispatch assembly instructions."
        )

    def test_basic_section_references_result_format_conformance(self) -> None:
        """SKILL.md BASIC section must reference RESULT format conformance for sub-agent output."""
        content = _read_skill()
        assert "RESULT" in content, (
            "Expected SKILL.md to contain 'RESULT' to reference the output schema "
            "that the BASIC investigation sub-agent must conform to. "
            "This is a RED test — SKILL.md does not yet reference RESULT format conformance."
        )

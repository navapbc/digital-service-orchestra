"""Tests for content requirements of the advanced-investigation-agent-b prompt template.

TDD spec for task w21-hb1j (RED task):
- plugins/dso/skills/fix-bug/prompts/advanced-investigation-agent-b.md must exist and contain:
  1. File exists at the expected path
  2. Timeline reconstruction language
  3. Fault tree analysis technique
  4. Git bisect technique
  5. Hypothesis generation from change history
  6. Self-reflection step before reporting root cause
  7. ROOT_CAUSE RESULT schema field
  8. Confidence RESULT schema field
  9. Context placeholder tokens: '{failing_tests}', '{stack_trace}', '{commit_history}'
  10. RESULT output section marker
  11. At least 2 proposed fixes language
  12. convergence_score RESULT field (ADVANCED adds this to schema)
  13. fishbone_categories RESULT field
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PROMPT_FILE = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "fix-bug"
    / "prompts"
    / "advanced-investigation-agent-b.md"
)


def _read_prompt() -> str:
    return PROMPT_FILE.read_text()


def test_advanced_investigation_agent_b_prompt_file_exists() -> None:
    """The advanced-investigation-agent-b.md prompt file must exist at the expected path."""
    assert PROMPT_FILE.exists(), (
        f"Expected advanced-investigation-agent-b prompt to exist at {PROMPT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created."
    )


def test_advanced_investigation_agent_b_prompt_timeline_reconstruction() -> None:
    """Prompt must contain timeline reconstruction language."""
    content = _read_prompt()
    assert "timeline reconstruction" in content or "timeline" in content, (
        "Expected advanced-investigation-agent-b.md to contain 'timeline reconstruction' or "
        "'timeline' language to guide the historical lens agent through systematic "
        "reconstruction of how the bug was introduced over time."
    )


def test_advanced_investigation_agent_b_prompt_fault_tree_analysis() -> None:
    """Prompt must contain fault tree analysis technique."""
    content = _read_prompt()
    assert "fault tree" in content, (
        "Expected advanced-investigation-agent-b.md to contain 'fault tree' to guide "
        "the sub-agent through structured fault tree analysis when tracing the "
        "historical chain of failures leading to the bug."
    )


def test_advanced_investigation_agent_b_prompt_git_bisect() -> None:
    """Prompt must contain 'git bisect' technique reference."""
    content = _read_prompt()
    assert "git bisect" in content, (
        "Expected advanced-investigation-agent-b.md to contain 'git bisect' to guide "
        "the historical lens agent through binary search of commit history to "
        "identify the commit that introduced the regression."
    )


def test_advanced_investigation_agent_b_prompt_hypothesis_generation() -> None:
    """Prompt must contain hypothesis generation from change history."""
    content = _read_prompt()
    assert "hypothesis" in content, (
        "Expected advanced-investigation-agent-b.md to contain 'hypothesis' to require "
        "the sub-agent to generate hypotheses from change history during investigation, "
        "ruling out alternative causes before settling on the root cause."
    )


def test_advanced_investigation_agent_b_prompt_self_reflection() -> None:
    """Prompt must contain 'self-reflection' to require sub-agent validation before reporting."""
    content = _read_prompt()
    assert "self-reflection" in content, (
        "Expected advanced-investigation-agent-b.md to contain 'self-reflection' to require "
        "the sub-agent to critically evaluate its root cause hypothesis before "
        "finalizing and reporting the result."
    )


def test_advanced_investigation_agent_b_prompt_root_cause_field() -> None:
    """Prompt must contain 'ROOT_CAUSE' as a RESULT schema field."""
    content = _read_prompt()
    assert "ROOT_CAUSE" in content, (
        "Expected advanced-investigation-agent-b.md to contain 'ROOT_CAUSE' as a required "
        "field in the RESULT output schema, conforming to the fix-bug skill's "
        "shared RESULT schema."
    )


def test_advanced_investigation_agent_b_prompt_confidence_field() -> None:
    """Prompt must contain 'confidence' as a RESULT schema field."""
    content = _read_prompt()
    assert "confidence" in content, (
        "Expected advanced-investigation-agent-b.md to contain 'confidence' as a required "
        "field in the RESULT output schema to quantify certainty in the root cause."
    )


def test_advanced_investigation_agent_b_prompt_failing_tests_placeholder() -> None:
    """Prompt must contain '{failing_tests}' context placeholder token."""
    content = _read_prompt()
    assert "{failing_tests}" in content, (
        "Expected advanced-investigation-agent-b.md to contain '{failing_tests}' as a "
        "context placeholder token for pre-loaded failing test output."
    )


def test_advanced_investigation_agent_b_prompt_stack_trace_placeholder() -> None:
    """Prompt must contain '{stack_trace}' context placeholder token."""
    content = _read_prompt()
    assert "{stack_trace}" in content, (
        "Expected advanced-investigation-agent-b.md to contain '{stack_trace}' as a "
        "context placeholder token for pre-loaded stack trace information."
    )


def test_advanced_investigation_agent_b_prompt_commit_history_placeholder() -> None:
    """Prompt must contain '{commit_history}' context placeholder token."""
    content = _read_prompt()
    assert "{commit_history}" in content, (
        "Expected advanced-investigation-agent-b.md to contain '{commit_history}' as a "
        "context placeholder token for pre-loaded recent commit history."
    )


def test_advanced_investigation_agent_b_prompt_result_section_marker() -> None:
    """Prompt must contain 'RESULT' output section marker."""
    content = _read_prompt()
    assert "RESULT" in content, (
        "Expected advanced-investigation-agent-b.md to contain 'RESULT' as an output "
        "section marker delineating the structured result block from narrative text."
    )


def test_advanced_investigation_agent_b_prompt_alternative_fixes() -> None:
    """Prompt must contain language about at least 2 proposed fixes."""
    content = _read_prompt()
    assert (
        "alternative_fixes" in content
        or "alternative fixes" in content
        or "at least 2" in content
        or "at least two" in content
    ), (
        "Expected advanced-investigation-agent-b.md to contain 'alternative_fixes' or "
        "language requiring at least 2 proposed fixes, so the caller can choose "
        "the most appropriate remediation rather than receiving only one option."
    )


def test_advanced_investigation_agent_b_prompt_convergence_score_field() -> None:
    """Prompt must contain 'convergence_score' as a RESULT schema field (ADVANCED-specific)."""
    content = _read_prompt()
    assert "convergence_score" in content, (
        "Expected advanced-investigation-agent-b.md to contain 'convergence_score' as a "
        "required field in the RESULT output schema. This field is unique to the ADVANCED "
        "investigation tier and is used for multi-agent convergence scoring."
    )


def test_advanced_investigation_agent_b_prompt_fishbone_categories_field() -> None:
    """Prompt must contain 'fishbone_categories' as a RESULT schema field."""
    content = _read_prompt()
    assert "fishbone_categories" in content, (
        "Expected advanced-investigation-agent-b.md to contain 'fishbone_categories' as a "
        "required field in the RESULT output schema to support structured root cause "
        "categorization using the fishbone (Ishikawa) diagram methodology."
    )

"""Tests for content requirements of the intermediate-investigation prompt template.

TDD spec for task w21-j4i9 (RED task):
- plugins/dso/skills/fix-bug/prompts/intermediate-investigation.md must exist and contain:
  1. File exists at the expected path
  2. Dependency-ordered code reading technique language
  3. Intermediate variable tracking technique
  4. Five whys analysis technique
  5. Hypothesis generation/elimination technique
  6. Self-reflection step before reporting root cause
  7. ROOT_CAUSE RESULT schema field
  8. Confidence RESULT schema field
  9. Context placeholder tokens: '{failing_tests}', '{stack_trace}', '{commit_history}'
  10. RESULT output section marker
  11. Alternative fixes or language about at least 2 proposed fixes
  12. Fallback file exists at plugins/dso/skills/fix-bug/prompts/intermediate-investigation-fallback.md
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
    / "intermediate-investigation.md"
)
FALLBACK_FILE = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "fix-bug"
    / "prompts"
    / "intermediate-investigation-fallback.md"
)


def _read_prompt() -> str:
    return PROMPT_FILE.read_text()


def test_intermediate_investigation_prompt_file_exists() -> None:
    """The intermediate-investigation.md prompt file must exist at the expected path."""
    assert PROMPT_FILE.exists(), (
        f"Expected intermediate-investigation prompt to exist at {PROMPT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created."
    )


def test_intermediate_investigation_prompt_dependency_ordered_reading() -> None:
    """Prompt must contain dependency-ordered code reading technique language."""
    content = _read_prompt()
    assert "dependency" in content or "dependency-ordered" in content, (
        "Expected intermediate-investigation.md to contain language about "
        "dependency-ordered code reading technique to guide deeper analysis "
        "by tracing code in dependency order rather than top-to-bottom."
    )


def test_intermediate_investigation_prompt_intermediate_variable_tracking() -> None:
    """Prompt must contain intermediate variable tracking technique."""
    content = _read_prompt()
    assert "intermediate variable" in content or "variable tracking" in content, (
        "Expected intermediate-investigation.md to contain language about "
        "intermediate variable tracking technique to identify where values "
        "diverge from expected state during execution."
    )


def test_intermediate_investigation_prompt_five_whys() -> None:
    """Prompt must contain 'five whys' root cause analysis technique."""
    content = _read_prompt()
    assert "five whys" in content, (
        "Expected intermediate-investigation.md to contain 'five whys' to guide "
        "the sub-agent through iterative root cause analysis before proposing a fix."
    )


def test_intermediate_investigation_prompt_hypothesis_elimination() -> None:
    """Prompt must contain hypothesis generation/elimination technique."""
    content = _read_prompt()
    assert "hypothesis" in content, (
        "Expected intermediate-investigation.md to contain 'hypothesis' to require "
        "the sub-agent to generate and eliminate hypotheses during investigation, "
        "ruling out alternative causes before settling on the root cause."
    )


def test_intermediate_investigation_prompt_self_reflection() -> None:
    """Prompt must contain 'self-reflection' to require sub-agent validation before reporting."""
    content = _read_prompt()
    assert "self-reflection" in content, (
        "Expected intermediate-investigation.md to contain 'self-reflection' to require "
        "the sub-agent to critically evaluate its root cause hypothesis before "
        "finalizing and reporting the result."
    )


def test_intermediate_investigation_prompt_root_cause_field() -> None:
    """Prompt must contain 'ROOT_CAUSE' as a RESULT schema field."""
    content = _read_prompt()
    assert "ROOT_CAUSE" in content, (
        "Expected intermediate-investigation.md to contain 'ROOT_CAUSE' as a required "
        "field in the RESULT output schema, conforming to the fix-bug skill's "
        "shared RESULT schema."
    )


def test_intermediate_investigation_prompt_confidence_field() -> None:
    """Prompt must contain 'confidence' as a RESULT schema field."""
    content = _read_prompt()
    assert "confidence" in content, (
        "Expected intermediate-investigation.md to contain 'confidence' as a required "
        "field in the RESULT output schema to quantify certainty in the root cause."
    )


def test_intermediate_investigation_prompt_failing_tests_placeholder() -> None:
    """Prompt must contain '{failing_tests}' context placeholder token."""
    content = _read_prompt()
    assert "{failing_tests}" in content, (
        "Expected intermediate-investigation.md to contain '{failing_tests}' as a "
        "context placeholder token for pre-loaded failing test output."
    )


def test_intermediate_investigation_prompt_stack_trace_placeholder() -> None:
    """Prompt must contain '{stack_trace}' context placeholder token."""
    content = _read_prompt()
    assert "{stack_trace}" in content, (
        "Expected intermediate-investigation.md to contain '{stack_trace}' as a "
        "context placeholder token for pre-loaded stack trace information."
    )


def test_intermediate_investigation_prompt_commit_history_placeholder() -> None:
    """Prompt must contain '{commit_history}' context placeholder token."""
    content = _read_prompt()
    assert "{commit_history}" in content, (
        "Expected intermediate-investigation.md to contain '{commit_history}' as a "
        "context placeholder token for pre-loaded recent commit history."
    )


def test_intermediate_investigation_prompt_result_section_marker() -> None:
    """Prompt must contain 'RESULT' output section marker."""
    content = _read_prompt()
    assert "RESULT" in content, (
        "Expected intermediate-investigation.md to contain 'RESULT' as an output "
        "section marker delineating the structured result block from narrative text."
    )


def test_intermediate_investigation_prompt_alternative_fixes() -> None:
    """Prompt must contain language about at least 2 proposed fixes."""
    content = _read_prompt()
    assert (
        "alternative_fixes" in content
        or "alternative fixes" in content
        or "at least 2" in content
        or "at least two" in content
    ), (
        "Expected intermediate-investigation.md to contain 'alternative_fixes' or "
        "language requiring at least 2 proposed fixes, so the caller can choose "
        "the most appropriate remediation rather than receiving only one option."
    )


def test_intermediate_investigation_fallback_file_exists() -> None:
    """The intermediate-investigation-fallback.md file must exist at the expected path.

    This test fails RED until task w21-sjie creates the fallback file.
    """
    assert FALLBACK_FILE.exists(), (
        f"Expected intermediate-investigation fallback prompt to exist at {FALLBACK_FILE}. "
        "This is a RED test — the fallback file does not exist yet and must be created "
        "by task w21-sjie."
    )


def test_intermediate_prompt_hypothesis_tests_fields() -> None:
    """Prompt must use hypothesis_tests (not tests_run) with sub-fields hypothesis, test, observed, verdict."""
    content = _read_prompt()
    # (a) hypothesis_tests present with correct sub-fields in RESULT schema block
    assert "hypothesis_tests" in content, (
        "Expected intermediate-investigation.md to contain 'hypothesis_tests' as the field name "
        "for hypothesis test results in the RESULT schema. This replaces the old 'tests_run' field."
    )
    for sub_field in ("hypothesis", "test", "observed", "verdict"):
        assert sub_field in content, (
            f"Expected intermediate-investigation.md to contain '{sub_field}' as a sub-field of "
            "hypothesis_tests in the RESULT schema."
        )
    # (b) Instructional prose references hypothesis_tests (not just in schema block)
    prose_lines = [
        line
        for line in content.splitlines()
        if "hypothesis_tests" in line
        and not line.strip().startswith("hypothesis_tests:")
    ]
    assert len(prose_lines) > 0, (
        "Expected intermediate-investigation.md to contain instructional prose referencing "
        "'hypothesis_tests' outside of the schema block."
    )
    # (c) Old tests_run field name is absent
    assert "tests_run" not in content, (
        "Expected intermediate-investigation.md to NOT contain 'tests_run' — this field has been "
        "renamed to 'hypothesis_tests'. All references to the old field name must be removed."
    )

"""Tests for content requirements of the escalated-investigation-agent-2 prompt template.

TDD spec for task dso-gnbz (RED task):
- plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-2.md must exist and contain:
  1. File exists at the expected path
  2. History Analyst role language
  3. Timeline reconstruction language
  4. Fault tree analysis technique
  5. Git bisect / bisection technique
  6. '{escalation_history}' placeholder token
  7. Context placeholder tokens: '{failing_tests}', '{stack_trace}', '{commit_history}'
  8. ROOT_CAUSE and confidence RESULT schema fields
  9. At least 3 proposed fixes language (ESCALATED requirement — extends ADVANCED's 2)
  10. Read-only constraint language
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
    / "escalated-investigation-agent-2.md"
)


def _read_prompt() -> str:
    return PROMPT_FILE.read_text()


def test_escalated_agent_2_prompt_file_exists() -> None:
    """The escalated-investigation-agent-2.md prompt file must exist at the expected path."""
    assert PROMPT_FILE.exists(), (
        f"Expected escalated-investigation-agent-2 prompt to exist at {PROMPT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created by dso-sjck."
    )


def test_escalated_agent_2_prompt_history_analyst_role() -> None:
    """Prompt must contain History Analyst role language."""
    content = _read_prompt()
    assert "History Analyst" in content or "history analyst" in content, (
        "Expected escalated-investigation-agent-2.md to contain 'History Analyst' or "
        "'history analyst' to establish the agent's specialized role in the ESCALATED "
        "investigation tier."
    )


def test_escalated_agent_2_prompt_timeline_reconstruction() -> None:
    """Prompt must contain timeline reconstruction language."""
    content = _read_prompt()
    assert "timeline reconstruction" in content or "timeline" in content, (
        "Expected escalated-investigation-agent-2.md to contain 'timeline reconstruction' "
        "or 'timeline' language to guide the History Analyst agent through systematic "
        "reconstruction of how the bug was introduced over time."
    )


def test_escalated_agent_2_prompt_fault_tree_analysis() -> None:
    """Prompt must contain fault tree analysis technique."""
    content = _read_prompt()
    assert "fault tree" in content, (
        "Expected escalated-investigation-agent-2.md to contain 'fault tree' to guide "
        "the sub-agent through structured fault tree analysis when tracing the "
        "historical chain of failures leading to the bug."
    )


def test_escalated_agent_2_prompt_commit_bisection() -> None:
    """Prompt must contain 'bisect' or 'bisection' technique reference."""
    content = _read_prompt()
    assert "bisect" in content or "bisection" in content, (
        "Expected escalated-investigation-agent-2.md to contain 'bisect' or 'bisection' "
        "to guide the History Analyst through binary search of commit history to "
        "identify the commit that introduced the regression."
    )


def test_escalated_agent_2_prompt_escalation_history_placeholder() -> None:
    """Prompt must contain '{escalation_history}' context placeholder token."""
    content = _read_prompt()
    assert "{escalation_history}" in content, (
        "Expected escalated-investigation-agent-2.md to contain '{escalation_history}' as "
        "a context placeholder token for the prior escalation context passed into the "
        "ESCALATED investigation tier from the caller."
    )


def test_escalated_agent_2_prompt_context_placeholders() -> None:
    """Prompt must contain '{failing_tests}', '{stack_trace}', '{commit_history}' tokens."""
    content = _read_prompt()
    assert "{failing_tests}" in content, (
        "Expected escalated-investigation-agent-2.md to contain '{failing_tests}' as a "
        "context placeholder token for pre-loaded failing test output."
    )
    assert "{stack_trace}" in content, (
        "Expected escalated-investigation-agent-2.md to contain '{stack_trace}' as a "
        "context placeholder token for pre-loaded stack trace information."
    )
    assert "{commit_history}" in content, (
        "Expected escalated-investigation-agent-2.md to contain '{commit_history}' as a "
        "context placeholder token for pre-loaded recent commit history."
    )


def test_escalated_agent_2_prompt_result_schema() -> None:
    """Prompt must contain 'ROOT_CAUSE' and 'confidence' as RESULT schema fields."""
    content = _read_prompt()
    assert "ROOT_CAUSE" in content, (
        "Expected escalated-investigation-agent-2.md to contain 'ROOT_CAUSE' as a required "
        "field in the RESULT output schema, conforming to the fix-bug skill's "
        "shared RESULT schema."
    )
    assert "confidence" in content, (
        "Expected escalated-investigation-agent-2.md to contain 'confidence' as a required "
        "field in the RESULT output schema to quantify certainty in the root cause."
    )


def test_escalated_agent_2_prompt_at_least_3_fixes() -> None:
    """Prompt must require at least 3 proposed fixes (ESCALATED extends ADVANCED's 2)."""
    content = _read_prompt()
    assert "at least 3" in content or "three" in content, (
        "Expected escalated-investigation-agent-2.md to require 'at least 3' or 'three' "
        "proposed fixes. The ESCALATED tier extends the ADVANCED tier's minimum of 2 fixes "
        "to 3, ensuring broader remediation options for severe bugs."
    )


def test_escalated_agent_2_prompt_read_only_constraint() -> None:
    """Prompt must contain read-only constraint language."""
    content = _read_prompt()
    assert "read-only" in content or "do not modify" in content, (
        "Expected escalated-investigation-agent-2.md to contain 'read-only' or "
        "'do not modify' to enforce that the History Analyst is an investigation-only "
        "agent and must not make code changes during its analysis phase."
    )


def test_escalated_2_prompt_hypothesis_tests_fields() -> None:
    """Prompt must use hypothesis_tests (not tests_run) with sub-fields hypothesis, test, observed, verdict."""
    content = _read_prompt()
    # (a) hypothesis_tests present with correct sub-fields in RESULT schema block
    assert "hypothesis_tests" in content, (
        "Expected escalated-investigation-agent-2.md to contain 'hypothesis_tests' as the field "
        "name for hypothesis test results in the RESULT schema. This replaces the old 'tests_run' field."
    )
    for sub_field in ("hypothesis", "test", "observed", "verdict"):
        assert sub_field in content, (
            f"Expected escalated-investigation-agent-2.md to contain '{sub_field}' as a sub-field of "
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
        "Expected escalated-investigation-agent-2.md to contain instructional prose referencing "
        "'hypothesis_tests' outside of the schema block."
    )
    # (c) Old tests_run field name is absent
    assert "tests_run" not in content, (
        "Expected escalated-investigation-agent-2.md to NOT contain 'tests_run' — this field has been "
        "renamed to 'hypothesis_tests'. All references to the old field name must be removed."
    )

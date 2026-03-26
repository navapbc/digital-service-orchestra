"""Tests for content requirements of the escalated-investigation-agent-3 prompt template.

TDD spec for task dso-t28s (RED task):
- plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-3.md must exist and contain:
  1. File exists at the expected path
  2. Code Tracer role framing
  3. Execution path tracing language
  4. Dependency-ordered reading (ESCALATED adds this to code tracer)
  5. Intermediate variable tracking technique
  6. Five whys analysis technique
  7. Context placeholder tokens: '{failing_tests}', '{stack_trace}', '{commit_history}',
     '{escalation_history}'
  8. ROOT_CAUSE and confidence RESULT schema fields
  9. At least 3 proposed fixes language (ESCALATED tier)
  10. Read-only constraint (all agents except Agent 4 are read-only)
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
    / "escalated-investigation-agent-3.md"
)


def _read_prompt() -> str:
    return PROMPT_FILE.read_text()


def test_escalated_agent_3_prompt_file_exists() -> None:
    """The escalated-investigation-agent-3.md prompt file must exist at the expected path."""
    assert PROMPT_FILE.exists(), (
        f"Expected escalated-investigation-agent-3 prompt to exist at {PROMPT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created by dso-cxuh."
    )


def test_escalated_agent_3_prompt_code_tracer_role() -> None:
    """Prompt must contain 'Code Tracer' or 'code tracer' role framing."""
    content = _read_prompt()
    assert "Code Tracer" in content or "code tracer" in content, (
        "Expected escalated-investigation-agent-3.md to contain 'Code Tracer' or "
        "'code tracer' to frame the agent's role as a code-tracing specialist "
        "investigating the execution path leading to the escalated bug."
    )


def test_escalated_agent_3_prompt_execution_path_tracing() -> None:
    """Prompt must contain execution path tracing language."""
    content = _read_prompt()
    assert "execution path" in content, (
        "Expected escalated-investigation-agent-3.md to contain 'execution path' to guide "
        "the code tracer agent through systematic tracing of the execution path "
        "leading to the bug."
    )


def test_escalated_agent_3_prompt_dependency_ordered_reading() -> None:
    """Prompt must contain dependency-ordered reading technique (ESCALATED adds this)."""
    content = _read_prompt()
    assert "dependency-ordered" in content or "dependency ordered" in content, (
        "Expected escalated-investigation-agent-3.md to contain 'dependency-ordered' or "
        "'dependency ordered' reading technique. This is an ESCALATED-tier extension to "
        "the code tracer role — files must be read in dependency order to trace the "
        "call graph from entry point to failure site."
    )


def test_escalated_agent_3_prompt_intermediate_variable_tracking() -> None:
    """Prompt must contain intermediate variable tracking technique."""
    content = _read_prompt()
    assert "intermediate variable" in content or "variable tracking" in content, (
        "Expected escalated-investigation-agent-3.md to contain 'intermediate variable' or "
        "'variable tracking' technique to identify where values diverge from expected "
        "state during execution in the escalated investigation."
    )


def test_escalated_agent_3_prompt_five_whys() -> None:
    """Prompt must contain 'five whys' root cause analysis technique."""
    content = _read_prompt()
    assert "five whys" in content, (
        "Expected escalated-investigation-agent-3.md to contain 'five whys' to guide "
        "the sub-agent through iterative root cause analysis before proposing fixes. "
        "This technique is shared between ADVANCED Agent A and ESCALATED Agent 3."
    )


def test_escalated_agent_3_prompt_escalation_history_placeholder() -> None:
    """Prompt must contain '{escalation_history}' placeholder (ESCALATED-tier unique token)."""
    content = _read_prompt()
    assert "{escalation_history}" in content, (
        "Expected escalated-investigation-agent-3.md to contain '{escalation_history}' as a "
        "context placeholder token. This token is unique to ESCALATED tier prompts and carries "
        "the history of previous investigation attempts so Agent 3 can avoid repeating "
        "already-ruled-out hypotheses."
    )


def test_escalated_agent_3_prompt_context_placeholders() -> None:
    """Prompt must contain all four required context placeholder tokens."""
    content = _read_prompt()
    missing = [
        token
        for token in [
            "{failing_tests}",
            "{stack_trace}",
            "{commit_history}",
            "{escalation_history}",
        ]
        if token not in content
    ]
    assert not missing, (
        f"Expected escalated-investigation-agent-3.md to contain context placeholder tokens "
        f"for pre-loaded context. Missing tokens: {missing}. "
        "The '{escalation_history}' token is unique to ESCALATED tier prompts and carries "
        "the history of previous investigation attempts."
    )


def test_escalated_agent_3_prompt_result_schema() -> None:
    """Prompt must contain 'ROOT_CAUSE' and 'confidence' as RESULT schema fields."""
    content = _read_prompt()
    assert "ROOT_CAUSE" in content, (
        "Expected escalated-investigation-agent-3.md to contain 'ROOT_CAUSE' as a required "
        "field in the RESULT output schema, conforming to the fix-bug skill's shared "
        "RESULT schema."
    )
    assert "confidence" in content, (
        "Expected escalated-investigation-agent-3.md to contain 'confidence' as a required "
        "field in the RESULT output schema to quantify certainty in the root cause."
    )


def test_escalated_agent_3_prompt_at_least_3_fixes() -> None:
    """Prompt must require at least 3 proposed fixes (ESCALATED tier requirement)."""
    content = _read_prompt()
    assert (
        "at least 3" in content or "at least three" in content or "three" in content
    ), (
        "Expected escalated-investigation-agent-3.md to contain language requiring at least 3 "
        "proposed fixes. ESCALATED agents must propose at least 3 fixes not already attempted, "
        "providing broader remediation options than ADVANCED tier agents."
    )


def test_escalated_agent_3_prompt_read_only_constraint() -> None:
    """Prompt must contain a read-only or do-not-modify constraint."""
    content = _read_prompt()
    assert "read-only" in content or "do not modify" in content, (
        "Expected escalated-investigation-agent-3.md to contain 'read-only' or 'do not modify' "
        "constraint. All ESCALATED investigation agents except Agent 4 are read-only — they "
        "investigate and report but do not apply code changes."
    )


def test_escalated_3_prompt_hypothesis_tests_fields() -> None:
    """Prompt must use hypothesis_tests (not tests_run) with sub-fields hypothesis, test, observed, verdict."""
    content = _read_prompt()
    # (a) hypothesis_tests present with correct sub-fields in RESULT schema block
    assert "hypothesis_tests" in content, (
        "Expected escalated-investigation-agent-3.md to contain 'hypothesis_tests' as the field "
        "name for hypothesis test results in the RESULT schema. This replaces the old 'tests_run' field."
    )
    for sub_field in ("hypothesis", "test", "observed", "verdict"):
        assert sub_field in content, (
            f"Expected escalated-investigation-agent-3.md to contain '{sub_field}' as a sub-field of "
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
        "Expected escalated-investigation-agent-3.md to contain instructional prose referencing "
        "'hypothesis_tests' outside of the schema block."
    )
    # (c) Old tests_run field name is absent
    assert "tests_run" not in content, (
        "Expected escalated-investigation-agent-3.md to NOT contain 'tests_run' — this field has been "
        "renamed to 'hypothesis_tests'. All references to the old field name must be removed."
    )

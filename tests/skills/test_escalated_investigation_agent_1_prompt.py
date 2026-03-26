"""Tests for content requirements of the escalated-investigation-agent-1 prompt template.

TDD spec for task dso-6xe1 (RED task):
- plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-1.md must exist and contain:
  1. File exists at the expected path
  2. Web Researcher role framing
  3. WebSearch or WebFetch authorized tools
  4. Error pattern analysis technique
  5. Similar issue correlation technique
  6. Changelog / dependency changelog analysis
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
    / "escalated-investigation-agent-1.md"
)


def _read_prompt() -> str:
    return PROMPT_FILE.read_text()


def test_escalated_agent_1_prompt_file_exists() -> None:
    """The escalated-investigation-agent-1.md prompt file must exist at the expected path."""
    assert PROMPT_FILE.exists(), (
        f"Expected escalated-investigation-agent-1 prompt to exist at {PROMPT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created by dso-mn94."
    )


def test_escalated_agent_1_prompt_web_researcher_role() -> None:
    """Prompt must contain 'Web Researcher' or 'web researcher' role framing."""
    content = _read_prompt()
    assert "Web Researcher" in content or "web researcher" in content, (
        "Expected escalated-investigation-agent-1.md to contain 'Web Researcher' or "
        "'web researcher' to frame the agent's role as a web-based research specialist "
        "investigating external context for the escalated bug."
    )


def test_escalated_agent_1_prompt_websearch_authorization() -> None:
    """Prompt must authorize WebSearch or WebFetch tools."""
    content = _read_prompt()
    assert "WebSearch" in content or "WebFetch" in content, (
        "Expected escalated-investigation-agent-1.md to contain 'WebSearch' or 'WebFetch' "
        "to authorize the agent to use web search tools for external investigation of "
        "error patterns and known issues."
    )


def test_escalated_agent_1_prompt_error_pattern_analysis() -> None:
    """Prompt must contain 'error pattern' as the primary investigation technique."""
    content = _read_prompt()
    assert "error pattern" in content, (
        "Expected escalated-investigation-agent-1.md to contain 'error pattern' to require "
        "the web researcher agent to search for and analyze error patterns encountered "
        "in similar projects or library versions."
    )


def test_escalated_agent_1_prompt_similar_issue_correlation() -> None:
    """Prompt must contain 'similar issue' correlation technique."""
    content = _read_prompt()
    assert "similar issue" in content, (
        "Expected escalated-investigation-agent-1.md to contain 'similar issue' to require "
        "the agent to correlate the observed failure with known similar issues in "
        "issue trackers, forums, or documentation."
    )


def test_escalated_agent_1_prompt_dependency_changelogs() -> None:
    """Prompt must contain 'changelog' or 'dependency changelog' analysis technique."""
    content = _read_prompt()
    assert "changelog" in content or "dependency changelog" in content, (
        "Expected escalated-investigation-agent-1.md to contain 'changelog' or "
        "'dependency changelog' to require the agent to check dependency release notes "
        "and changelogs for breaking changes related to the observed failure."
    )


def test_escalated_agent_1_prompt_context_placeholders() -> None:
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
        f"Expected escalated-investigation-agent-1.md to contain context placeholder tokens "
        f"for pre-loaded context. Missing tokens: {missing}. "
        "The '{escalation_history}' token is unique to ESCALATED tier prompts and carries "
        "the history of previous investigation attempts."
    )


def test_escalated_agent_1_prompt_result_schema() -> None:
    """Prompt must contain 'ROOT_CAUSE' and 'confidence' as RESULT schema fields."""
    content = _read_prompt()
    assert "ROOT_CAUSE" in content, (
        "Expected escalated-investigation-agent-1.md to contain 'ROOT_CAUSE' as a required "
        "field in the RESULT output schema, conforming to the fix-bug skill's shared "
        "RESULT schema."
    )
    assert "confidence" in content, (
        "Expected escalated-investigation-agent-1.md to contain 'confidence' as a required "
        "field in the RESULT output schema to quantify certainty in the root cause."
    )


def test_escalated_agent_1_prompt_at_least_3_fixes() -> None:
    """Prompt must require at least 3 proposed fixes (ESCALATED tier requirement)."""
    content = _read_prompt()
    assert (
        "at least 3" in content or "at least three" in content or "three" in content
    ), (
        "Expected escalated-investigation-agent-1.md to contain language requiring at least 3 "
        "proposed fixes. ESCALATED agents must propose at least 3 fixes not already attempted, "
        "providing broader remediation options than ADVANCED tier agents."
    )


def test_escalated_agent_1_prompt_read_only_constraint() -> None:
    """Prompt must contain a read-only or do-not-modify constraint."""
    content = _read_prompt()
    assert "read-only" in content or "do not modify" in content, (
        "Expected escalated-investigation-agent-1.md to contain 'read-only' or 'do not modify' "
        "constraint. All ESCALATED investigation agents except Agent 4 are read-only — they "
        "investigate and report but do not apply code changes."
    )


def test_escalated_1_prompt_hypothesis_tests_fields() -> None:
    """Prompt must use hypothesis_tests (not tests_run) with sub-fields hypothesis, test, observed, verdict."""
    content = _read_prompt()
    # (a) hypothesis_tests present with correct sub-fields in RESULT schema block
    assert "hypothesis_tests" in content, (
        "Expected escalated-investigation-agent-1.md to contain 'hypothesis_tests' as the field "
        "name for hypothesis test results in the RESULT schema. This replaces the old 'tests_run' field."
    )
    for sub_field in ("hypothesis", "test", "observed", "verdict"):
        assert sub_field in content, (
            f"Expected escalated-investigation-agent-1.md to contain '{sub_field}' as a sub-field of "
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
        "Expected escalated-investigation-agent-1.md to contain instructional prose referencing "
        "'hypothesis_tests' outside of the schema block."
    )
    # (c) Old tests_run field name is absent
    assert "tests_run" not in content, (
        "Expected escalated-investigation-agent-1.md to NOT contain 'tests_run' — this field has been "
        "renamed to 'hypothesis_tests'. All references to the old field name must be removed."
    )

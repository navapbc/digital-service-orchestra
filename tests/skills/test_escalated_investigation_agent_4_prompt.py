"""Tests for content requirements of the escalated-investigation-agent-4 prompt template.

TDD spec for task dso-ezme (RED task):
- plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-4.md must exist and contain:
  1. File exists at the expected path
  2. Empirical/Logging Agent role framing
  3. Authorization to add logging
  4. Authorization to enable debugging
  5. Veto authority over agents 1-3
  6. Artifact revert requirement (logging/debugging additions must not persist)
  7. '{escalation_history}' context placeholder
  8. Context placeholders: '{failing_tests}', '{stack_trace}', '{commit_history}'
  9. ROOT_CAUSE and confidence RESULT schema fields
  10. At least 3 proposed fixes language
  11. Validates or vetoes hypotheses from agents 1-3
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
    / "escalated-investigation-agent-4.md"
)


def _read_prompt() -> str:
    return PROMPT_FILE.read_text()


def test_escalated_agent_4_prompt_file_exists() -> None:
    """The escalated-investigation-agent-4.md prompt file must exist at the expected path."""
    assert PROMPT_FILE.exists(), (
        f"Expected escalated-investigation-agent-4 prompt to exist at {PROMPT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created by dso-56g6."
    )


def test_escalated_agent_4_prompt_empirical_agent_role() -> None:
    """Prompt must contain 'Empirical' or 'empirical' for role framing."""
    content = _read_prompt()
    assert "Empirical" in content or "empirical" in content, (
        "Expected escalated-investigation-agent-4.md to contain 'Empirical' or 'empirical' "
        "to frame Agent 4's role as the Empirical/Logging Agent — the agent that validates "
        "or vetoes hypotheses from agents 1-3 through empirical evidence gathering."
    )


def test_escalated_agent_4_prompt_logging_authorization() -> None:
    """Prompt must contain authorization to add logging."""
    content = _read_prompt()
    assert "logging" in content or "add logging" in content, (
        "Expected escalated-investigation-agent-4.md to contain 'logging' or 'add logging' "
        "to document that Agent 4 is uniquely authorized to add temporary logging statements "
        "as an empirical investigation technique not available to agents 1-3."
    )


def test_escalated_agent_4_prompt_debugging_authorization() -> None:
    """Prompt must contain authorization to enable debugging."""
    content = _read_prompt()
    assert "debugging" in content or "enable debugging" in content, (
        "Expected escalated-investigation-agent-4.md to contain 'debugging' or 'enable debugging' "
        "to document that Agent 4 is authorized to enable debugging instrumentation to gather "
        "empirical evidence for validating or vetoing hypotheses from agents 1-3."
    )


def test_escalated_agent_4_prompt_veto_authority() -> None:
    """Prompt must contain 'veto' — Agent 4's unique power to reject agents 1-3 hypotheses."""
    content = _read_prompt()
    assert "veto" in content, (
        "Expected escalated-investigation-agent-4.md to contain 'veto' to document Agent 4's "
        "unique authority to veto hypotheses from agents 1-3 when empirical evidence "
        "contradicts their static analysis conclusions. This is the core differentiator "
        "for the Empirical/Logging Agent role in the escalated investigation tier."
    )


def test_escalated_agent_4_prompt_artifact_revert() -> None:
    """Prompt must require reverting/stashing temporary logging and debugging artifacts."""
    content = _read_prompt()
    assert "revert" in content or "stash" in content, (
        "Expected escalated-investigation-agent-4.md to contain 'revert' or 'stash' to "
        "require Agent 4 to clean up all temporary logging and debugging artifacts after "
        "investigation. Logging and debugging additions must not persist in the codebase."
    )


def test_escalated_agent_4_prompt_escalation_history_placeholder() -> None:
    """Prompt must contain '{escalation_history}' context placeholder token."""
    content = _read_prompt()
    assert "{escalation_history}" in content, (
        "Expected escalated-investigation-agent-4.md to contain '{escalation_history}' as a "
        "context placeholder token for the aggregated findings from agents 1-3 that Agent 4 "
        "will empirically validate or veto. This placeholder is unique to the ESCALATED tier."
    )


def test_escalated_agent_4_prompt_context_placeholders() -> None:
    """Prompt must contain '{failing_tests}', '{stack_trace}', and '{commit_history}' placeholders."""
    content = _read_prompt()
    assert "{failing_tests}" in content, (
        "Expected escalated-investigation-agent-4.md to contain '{failing_tests}' as a "
        "context placeholder token for pre-loaded failing test output."
    )
    assert "{stack_trace}" in content, (
        "Expected escalated-investigation-agent-4.md to contain '{stack_trace}' as a "
        "context placeholder token for pre-loaded stack trace information."
    )
    assert "{commit_history}" in content, (
        "Expected escalated-investigation-agent-4.md to contain '{commit_history}' as a "
        "context placeholder token for pre-loaded recent commit history."
    )


def test_escalated_agent_4_prompt_result_schema() -> None:
    """Prompt must contain 'ROOT_CAUSE' and 'confidence' as RESULT schema fields."""
    content = _read_prompt()
    assert "ROOT_CAUSE" in content, (
        "Expected escalated-investigation-agent-4.md to contain 'ROOT_CAUSE' as a required "
        "field in the RESULT output schema, conforming to the fix-bug skill's shared RESULT schema."
    )
    assert "confidence" in content, (
        "Expected escalated-investigation-agent-4.md to contain 'confidence' as a required "
        "field in the RESULT output schema to quantify Agent 4's certainty in the empirically "
        "validated root cause."
    )


def test_escalated_agent_4_prompt_at_least_3_fixes() -> None:
    """Prompt must require at least 3 proposed fixes (more than standard/advanced agents)."""
    content = _read_prompt()
    assert "at least 3" in content or "three" in content, (
        "Expected escalated-investigation-agent-4.md to contain 'at least 3' or 'three' to "
        "require Agent 4 to propose at least 3 fix alternatives — more than the 2 required "
        "from standard/advanced agents, reflecting the deeper empirical analysis performed."
    )


def test_escalated_agent_4_prompt_validates_or_vetoes() -> None:
    """Prompt must contain 'validate' or 'validates' — empirically validates or vetoes agent 1-3 hypotheses."""
    content = _read_prompt()
    assert "validate" in content or "validates" in content, (
        "Expected escalated-investigation-agent-4.md to contain 'validate' or 'validates' to "
        "describe Agent 4's primary responsibility: empirically validating or vetoing the "
        "hypotheses produced by agents 1-3 using logging and debugging instrumentation."
    )

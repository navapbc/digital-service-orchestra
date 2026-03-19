"""Tests for content requirements of the basic-investigation prompt template.

TDD spec for task w21-vlje (RED task):
- plugins/dso/skills/fix-bug/prompts/basic-investigation.md must exist and contain:
  1. File exists at the expected path
  2. Structured localization language: 'file', 'class' or 'function', and 'line'
  3. 'five whys' analysis technique
  4. 'self-reflection' before reporting root cause
  5. 'ROOT_CAUSE' RESULT schema field
  6. 'confidence' RESULT schema field
  7. Context placeholder tokens: '{failing_tests}', '{stack_trace}', '{commit_history}'
  8. 'RESULT' output section marker
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
    / "basic-investigation.md"
)


def _read_prompt() -> str:
    return PROMPT_FILE.read_text()


def test_basic_investigation_prompt_file_exists() -> None:
    """The basic-investigation.md prompt file must exist at the expected path."""
    assert PROMPT_FILE.exists(), (
        f"Expected basic-investigation prompt to exist at {PROMPT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created."
    )


def test_basic_investigation_prompt_localization_file() -> None:
    """Prompt must contain 'file' for structured bug location identification."""
    content = _read_prompt()
    assert "file" in content, (
        "Expected basic-investigation.md to contain 'file' as part of the "
        "structured localization language to identify the location of a bug."
    )


def test_basic_investigation_prompt_localization_function_or_class() -> None:
    """Prompt must contain 'class' or 'function' for structured bug localization."""
    content = _read_prompt()
    assert "class" in content or "function" in content, (
        "Expected basic-investigation.md to contain 'class' or 'function' as part of "
        "the structured localization language to identify the scope of a bug."
    )


def test_basic_investigation_prompt_localization_line() -> None:
    """Prompt must contain 'line' for structured bug location identification."""
    content = _read_prompt()
    assert "line" in content, (
        "Expected basic-investigation.md to contain 'line' as part of the "
        "structured localization language to pinpoint the exact bug location."
    )


def test_basic_investigation_prompt_five_whys() -> None:
    """Prompt must contain 'five whys' root cause analysis technique."""
    content = _read_prompt()
    assert "five whys" in content, (
        "Expected basic-investigation.md to contain 'five whys' to guide the "
        "sub-agent through iterative root cause analysis before proposing a fix."
    )


def test_basic_investigation_prompt_self_reflection() -> None:
    """Prompt must contain 'self-reflection' to require sub-agent validation before reporting."""
    content = _read_prompt()
    assert "self-reflection" in content, (
        "Expected basic-investigation.md to contain 'self-reflection' to require "
        "the sub-agent to critically evaluate its root cause hypothesis before "
        "finalizing and reporting the result."
    )


def test_basic_investigation_prompt_root_cause_field() -> None:
    """Prompt must contain 'ROOT_CAUSE' as a RESULT schema field."""
    content = _read_prompt()
    assert "ROOT_CAUSE" in content, (
        "Expected basic-investigation.md to contain 'ROOT_CAUSE' as a required "
        "field in the RESULT output schema, conforming to the fix-bug skill's "
        "shared RESULT schema."
    )


def test_basic_investigation_prompt_confidence_field() -> None:
    """Prompt must contain 'confidence' as a RESULT schema field."""
    content = _read_prompt()
    assert "confidence" in content, (
        "Expected basic-investigation.md to contain 'confidence' as a required "
        "field in the RESULT output schema to quantify certainty in the root cause."
    )


def test_basic_investigation_prompt_failing_tests_placeholder() -> None:
    """Prompt must contain '{failing_tests}' context placeholder token."""
    content = _read_prompt()
    assert "{failing_tests}" in content, (
        "Expected basic-investigation.md to contain '{failing_tests}' as a "
        "context placeholder token for pre-loaded failing test output."
    )


def test_basic_investigation_prompt_stack_trace_placeholder() -> None:
    """Prompt must contain '{stack_trace}' context placeholder token."""
    content = _read_prompt()
    assert "{stack_trace}" in content, (
        "Expected basic-investigation.md to contain '{stack_trace}' as a "
        "context placeholder token for pre-loaded stack trace information."
    )


def test_basic_investigation_prompt_commit_history_placeholder() -> None:
    """Prompt must contain '{commit_history}' context placeholder token."""
    content = _read_prompt()
    assert "{commit_history}" in content, (
        "Expected basic-investigation.md to contain '{commit_history}' as a "
        "context placeholder token for pre-loaded recent commit history."
    )


def test_basic_investigation_prompt_result_section_marker() -> None:
    """Prompt must contain 'RESULT' output section marker."""
    content = _read_prompt()
    assert "RESULT" in content, (
        "Expected basic-investigation.md to contain 'RESULT' as an output "
        "section marker delineating the structured result block from narrative text."
    )

"""Tests for content requirements of the completion-verifier agent definition.

TDD spec for task a866-c47b (RED task):
- plugins/dso/agents/completion-verifier.md must exist and contain:
  1. File exists at the expected path
  2. YAML frontmatter contains 'name: completion-verifier'
  3. YAML frontmatter contains 'model: sonnet'
  4. Markdown body contains SC/DD verification logic
  5. Markdown body contains consumer smoke test instructions
  6. Markdown body contains remediation task creation instructions
  7. Body explicitly excludes test pass/fail, code quality, lint/formatting from scope
  8. Body contains the framing: 'did we build what the spec says' not 'is the code correct'
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENT_FILE = REPO_ROOT / "plugins" / "dso" / "agents" / "completion-verifier.md"


def _read_agent() -> str:
    return AGENT_FILE.read_text()


def _parse_frontmatter(content: str) -> tuple[str, str]:
    """Return (frontmatter, body) split on the closing '---' delimiter."""
    if not content.startswith("---"):
        return ("", content)
    end = content.find("\n---", 3)
    if end == -1:
        return ("", content)
    frontmatter = content[3:end]
    body = content[end + 4 :]
    return (frontmatter, body)


def test_completion_verifier_agent_file_exists() -> None:
    """The completion-verifier.md agent file must exist at the expected path."""
    assert AGENT_FILE.exists(), (
        f"Expected completion-verifier agent to exist at {AGENT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created by the GREEN task."
    )


def test_completion_verifier_agent_frontmatter_name() -> None:
    """YAML frontmatter must contain 'name: completion-verifier'."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "name: completion-verifier" in frontmatter, (
        "Expected YAML frontmatter of completion-verifier.md to contain "
        "'name: completion-verifier'. The 'name' field uniquely identifies the agent "
        "and must match the file name convention."
    )


def test_completion_verifier_agent_frontmatter_model() -> None:
    """YAML frontmatter must specify 'model: sonnet'."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "model: sonnet" in frontmatter, (
        "Expected YAML frontmatter of completion-verifier.md to contain 'model: sonnet'. "
        "The completion verifier performs structured spec-vs-implementation verification; "
        "sonnet is the appropriate model tier for this reasoning task."
    )


def test_completion_verifier_agent_body_sc_dd_verification() -> None:
    """Markdown body must contain SC/DD verification logic.

    The agent must verify success criteria (SC) for epics and done definitions
    (DD) for stories against actual implementation state.
    """
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    # Must reference success criteria and done definitions
    assert re.search(r"success.criteri", body, re.IGNORECASE), (
        "Expected completion-verifier.md body to reference 'success criteria' verification "
        "logic. The agent must check that epic success criteria are demonstrably met."
    )
    assert re.search(r"done.definition|definition.of.done", body, re.IGNORECASE), (
        "Expected completion-verifier.md body to reference 'done definition' or "
        "'definition of done' verification logic. The agent must check that story "
        "done-definitions are satisfied."
    )


def test_completion_verifier_agent_body_consumer_smoke_tests() -> None:
    """Markdown body must contain consumer smoke test instructions.

    The agent must enumerate consumers and define verification commands
    to confirm integration points work correctly.
    """
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    assert re.search(
        r"smoke.test|consumer.*verif|verif.*consumer", body, re.IGNORECASE
    ), (
        "Expected completion-verifier.md body to contain consumer smoke test instructions. "
        "The agent must enumerate consumers of a feature and define verification commands "
        "to validate that integration points work as expected."
    )


def test_completion_verifier_agent_body_remediation_task_creation() -> None:
    """Markdown body must contain remediation task creation instructions.

    When verification failures are found, the agent must create bug tasks
    to track them for resolution.
    """
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    assert re.search(
        r"remediat|bug.task|create.*task.*fail|ticket.*creat", body, re.IGNORECASE
    ), (
        "Expected completion-verifier.md body to contain remediation task creation instructions. "
        "When verification finds a gap between spec and implementation, the agent must create "
        "bug tasks (via ticket create) to track the remediation work."
    )


def test_completion_verifier_agent_body_excludes_test_quality_lint() -> None:
    """Markdown body must explicitly exclude test pass/fail, code quality, lint/formatting.

    The agent's scope is spec-vs-implementation verification only; it must not
    perform code quality review, test result analysis, or linting.
    """
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    # Should mention what it does NOT do
    exclusion_patterns = [
        r"not.*test.*pass|test.*pass.*not|exclud.*test",
        r"not.*code.quality|code.quality.*not|exclud.*code.quality",
        r"not.*lint|lint.*not|exclud.*lint|exclud.*format",
    ]
    found_exclusions = [
        pattern
        for pattern in exclusion_patterns
        if re.search(pattern, body, re.IGNORECASE)
    ]
    assert len(found_exclusions) >= 2, (
        "Expected completion-verifier.md body to explicitly exclude at least 2 of: "
        "test pass/fail analysis, code quality review, lint/formatting checks. "
        f"Found {len(found_exclusions)} exclusion(s) out of 3 expected patterns. "
        "The agent's scope must be clearly bounded to spec verification only."
    )


def test_completion_verifier_agent_body_spec_framing() -> None:
    """Body must contain the 'did we build what the spec says' framing.

    The agent's guiding question distinguishes it from code review: it asks
    whether the implementation matches the spec, not whether the code is correct.
    """
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    assert re.search(
        r"did we build what the spec|spec says|what the spec|build what.*spec",
        body,
        re.IGNORECASE,
    ), (
        "Expected completion-verifier.md body to contain the framing "
        "'did we build what the spec says' (or equivalent phrasing). "
        "This framing distinguishes the agent's scope from code review: "
        "the question is spec conformance, not code correctness."
    )

    # The NOT framing should also be present
    assert re.search(
        r"not.*is the code correct|is the code correct.*not|not.*code.correct",
        body,
        re.IGNORECASE,
    ), (
        "Expected completion-verifier.md body to contrast 'did we build what the spec says' "
        "with 'is the code correct' — explicitly stating the agent does NOT evaluate "
        "code correctness. This boundary prevents scope creep into code review territory."
    )

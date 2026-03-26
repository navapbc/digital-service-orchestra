"""Tests for content requirements of the feasibility-reviewer agent definition.

TDD spec for task d80d-7efc (RED task):
- plugins/dso/agents/feasibility-reviewer.md must exist and contain:
  1. File exists at the expected path
  2. YAML frontmatter contains 'name: feasibility-reviewer'
  3. YAML frontmatter contains 'model: sonnet'
  4. Markdown body contains WebSearch instructions for verifying tool capabilities
  5. Markdown body contains GitHub code search instructions for known-working examples
  6. Markdown body contains Technical Feasibility output section
  7. Markdown body contains high-risk flagging with spike recommendation
  8. Markdown body contains integration signal categories (third-party CLI, external APIs,
     CI/CD, infrastructure, data migrations, auth/credential flows)
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENT_FILE = REPO_ROOT / "plugins" / "dso" / "agents" / "feasibility-reviewer.md"


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


def test_feasibility_reviewer_agent_file_exists() -> None:
    """The feasibility-reviewer.md agent file must exist at the expected path."""
    assert AGENT_FILE.exists(), (
        f"Expected feasibility-reviewer agent to exist at {AGENT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created by the "
        "GREEN task for story eea8-8de4."
    )


def test_feasibility_reviewer_agent_frontmatter_name() -> None:
    """YAML frontmatter must contain 'name: feasibility-reviewer'."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "name: feasibility-reviewer" in frontmatter, (
        "Expected YAML frontmatter of feasibility-reviewer.md to contain "
        "'name: feasibility-reviewer'. The 'name' field uniquely identifies the agent "
        "and must match the file name convention."
    )


def test_feasibility_reviewer_agent_frontmatter_model() -> None:
    """YAML frontmatter must specify 'model: sonnet'."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "model: sonnet" in frontmatter, (
        "Expected YAML frontmatter of feasibility-reviewer.md to contain 'model: sonnet'. "
        "The feasibility reviewer performs substantive research and analysis; sonnet is the "
        "appropriate model tier for this task."
    )


def test_feasibility_reviewer_agent_body_websearch_instructions() -> None:
    """Markdown body must contain WebSearch instructions for verifying tool capabilities."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)
    assert re.search(r"WebSearch", body), (
        "Expected feasibility-reviewer.md body to contain 'WebSearch' instructions. "
        "The agent must use WebSearch to verify that proposed tools/libraries/APIs are "
        "real, actively maintained, and capable of the required functionality."
    )


def test_feasibility_reviewer_agent_body_github_code_search() -> None:
    """Markdown body must contain GitHub code search instructions for known-working examples."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)
    assert re.search(
        r"github\.com|github code search|site:github\.com", body, re.IGNORECASE
    ), (
        "Expected feasibility-reviewer.md body to contain GitHub code search instructions. "
        "The agent must search GitHub for known-working examples of the proposed integration "
        "patterns to validate that real implementations exist."
    )


def test_feasibility_reviewer_agent_body_technical_feasibility_output() -> None:
    """Markdown body must contain a Technical Feasibility output section."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)
    assert re.search(r"technical.feasibility", body, re.IGNORECASE), (
        "Expected feasibility-reviewer.md body to contain a 'Technical Feasibility' "
        "output section. This section structures the agent's findings into a format "
        "that callers (e.g., /dso:implementation-plan) can interpret and act on."
    )


def test_feasibility_reviewer_agent_body_high_risk_flagging() -> None:
    """Markdown body must contain high-risk flagging with spike recommendation."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)
    assert re.search(r"high.risk|high_risk", body, re.IGNORECASE), (
        "Expected feasibility-reviewer.md body to contain high-risk flagging language. "
        "When integration risk is high, the agent must recommend a spike task before "
        "full implementation to de-risk the work."
    )
    assert re.search(r"spike", body, re.IGNORECASE), (
        "Expected feasibility-reviewer.md body to recommend a spike when risk is high. "
        "A spike is a time-boxed investigation task used to validate feasibility before "
        "committing to full implementation effort."
    )


def test_feasibility_reviewer_agent_body_integration_signal_categories() -> None:
    """Markdown body must contain all required integration signal categories."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    # Required integration signal categories from the task spec
    signal_categories = [
        (r"third.party.cli|third-party cli", "third-party CLI tools"),
        (r"external.api|external api", "external APIs"),
        (r"ci[/\-]cd|cicd", "CI/CD"),
        (r"infrastructure|infra", "infrastructure"),
        (r"data.migration", "data migrations"),
        (r"auth.*credential|credential.*auth|auth.flow", "auth/credential flows"),
    ]

    for pattern, label in signal_categories:
        assert re.search(pattern, body, re.IGNORECASE), (
            f"Expected feasibility-reviewer.md body to contain integration signal category "
            f"'{label}'. The agent must recognize this category as a signal that feasibility "
            f"research is warranted before implementation begins."
        )

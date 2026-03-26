"""Tests for content requirements of the red-team-reviewer agent definition.

TDD spec for task 3aed-e68a (RED task):
- plugins/dso/agents/red-team-reviewer.md must exist and contain:
  1. File exists at the expected path
  2. YAML frontmatter contains 'name: red-team-reviewer'
  3. YAML frontmatter contains 'model: opus'
  4. Markdown body contains all 6 taxonomy categories including Consumer Impact / Operational Readiness
  5. Markdown body contains the Consumer Enumeration directive
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENT_FILE = REPO_ROOT / "plugins" / "dso" / "agents" / "red-team-reviewer.md"


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


def test_red_team_reviewer_agent_file_exists() -> None:
    """The red-team-reviewer.md agent file must exist at the expected path."""
    assert AGENT_FILE.exists(), (
        f"Expected red-team-reviewer agent to exist at {AGENT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created by the GREEN task."
    )


def test_red_team_reviewer_agent_frontmatter_name() -> None:
    """YAML frontmatter must contain 'name: red-team-reviewer'."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "name: red-team-reviewer" in frontmatter, (
        "Expected YAML frontmatter of red-team-reviewer.md to contain "
        "'name: red-team-reviewer'. The 'name' field uniquely identifies the agent "
        "and must match the file name convention."
    )


def test_red_team_reviewer_agent_frontmatter_model() -> None:
    """YAML frontmatter must specify 'model: opus'."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "model: opus" in frontmatter, (
        "Expected YAML frontmatter of red-team-reviewer.md to contain 'model: opus'. "
        "The red team reviewer performs adversarial analysis requiring deep reasoning; "
        "opus is the appropriate model tier per agent routing conventions."
    )


def test_red_team_reviewer_agent_body_six_taxonomy_categories() -> None:
    """Markdown body must contain all 6 taxonomy categories."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    # The original 5 categories
    original_categories = [
        "implicit_shared_state",
        "conflicting_assumptions",
        "dependency_gap",
        "scope_overlap",
        "ordering_violation",
    ]
    for category in original_categories:
        assert category in body, (
            f"Expected red-team-reviewer.md body to reference taxonomy category "
            f"'{category}'. All 6 taxonomy categories must be present in the agent."
        )

    # The new 6th category — Consumer Impact / Operational Readiness
    consumer_impact_present = (
        "Consumer Impact" in body
        or "consumer_impact" in body
        or "Operational Readiness" in body
        or "operational_readiness" in body
    )
    assert consumer_impact_present, (
        "Expected red-team-reviewer.md body to contain the 6th taxonomy category: "
        "'Consumer Impact' or 'Operational Readiness' (or its snake_case form). "
        "This category catches downstream breakage from consumer-impacting changes."
    )


def test_red_team_reviewer_agent_body_consumer_enumeration_directive() -> None:
    """Markdown body must contain a Consumer Enumeration directive."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    consumer_enum_present = (
        "Consumer Enumeration" in body or "consumer enumeration" in body.lower()
    )
    assert consumer_enum_present, (
        "Expected red-team-reviewer.md body to contain a 'Consumer Enumeration' directive "
        "that instructs the agent to identify known consumers before analyzing stories. "
        "This directive is required per done definition SC3 in story 5805-11d3."
    )

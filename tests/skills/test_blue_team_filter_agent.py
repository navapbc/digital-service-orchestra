"""Tests for content requirements of the blue-team-filter agent definition.

TDD spec for task 3aed-e68a (RED task):
- plugins/dso/agents/blue-team-filter.md must exist and contain:
  1. File exists at the expected path
  2. YAML frontmatter contains 'name: blue-team-filter'
  3. YAML frontmatter contains 'model: sonnet'
  4. Markdown body contains artifact persistence instructions referencing ARTIFACTS_DIR or adversarial-review
  5. Markdown body contains full exchange persistence (both 'accepted' and 'rejected' findings)
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENT_FILE = REPO_ROOT / "plugins" / "dso" / "agents" / "blue-team-filter.md"


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


def test_blue_team_filter_agent_file_exists() -> None:
    """The blue-team-filter.md agent file must exist at the expected path."""
    assert AGENT_FILE.exists(), (
        f"Expected blue-team-filter agent to exist at {AGENT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created by the GREEN task."
    )


def test_blue_team_filter_agent_frontmatter_name() -> None:
    """YAML frontmatter must contain 'name: blue-team-filter'."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "name: blue-team-filter" in frontmatter, (
        "Expected YAML frontmatter of blue-team-filter.md to contain "
        "'name: blue-team-filter'. The 'name' field uniquely identifies the agent "
        "and must match the file name convention."
    )


def test_blue_team_filter_agent_frontmatter_model() -> None:
    """YAML frontmatter must specify 'model: sonnet'."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "model: sonnet" in frontmatter, (
        "Expected YAML frontmatter of blue-team-filter.md to contain 'model: sonnet'. "
        "The blue team filter is a structured filtering task; sonnet is the appropriate "
        "model tier per agent routing conventions and story 5805-11d3 spec."
    )


def test_blue_team_filter_agent_body_artifact_persistence() -> None:
    """Markdown body must contain artifact persistence instructions referencing ARTIFACTS_DIR or adversarial-review."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    artifacts_ref_present = "ARTIFACTS_DIR" in body or "adversarial-review" in body
    assert artifacts_ref_present, (
        "Expected blue-team-filter.md body to contain artifact persistence instructions "
        "referencing 'ARTIFACTS_DIR' or 'adversarial-review'. "
        "Per done definition SC3 in story 5805-11d3, the blue team filter must persist "
        "the full exchange to ARTIFACTS_DIR/adversarial-review-<epic-id>.json."
    )


def test_blue_team_filter_agent_body_full_exchange_persistence() -> None:
    """Markdown body must contain instructions for persisting both accepted and rejected findings."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    assert "accepted" in body.lower(), (
        "Expected blue-team-filter.md body to reference persisting 'accepted' findings. "
        "Full exchange persistence means both accepted and rejected findings are written "
        "to the artifact file for post-mortem analysis."
    )
    assert "rejected" in body.lower(), (
        "Expected blue-team-filter.md body to reference persisting 'rejected' findings. "
        "Full exchange persistence means both accepted and rejected findings are written "
        "to the artifact file for post-mortem analysis."
    )

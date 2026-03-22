"""Tests for content requirements of the complexity-evaluator agent definition.

TDD spec for task dso-mwxz (RED task):
- plugins/dso/agents/complexity-evaluator.md must exist and contain:
  1. File exists at the expected path
  2. YAML frontmatter contains 'name: complexity-evaluator'
  3. YAML frontmatter contains 'model: haiku'
  4. YAML frontmatter contains tools: with Bash, Read, Glob, Grep listed
  5. Markdown body contains 5-dimension rubric content
  6. Markdown body contains the tier_schema mechanism (tier vocabulary selector)
  7. Markdown body does NOT contain context-specific routing table
  8. Markdown body contains epic-specific qualitative override dimensions marked as epic-only
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENT_FILE = REPO_ROOT / "plugins" / "dso" / "agents" / "complexity-evaluator.md"


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


def test_complexity_evaluator_agent_file_exists() -> None:
    """The complexity-evaluator.md agent file must exist at the expected path."""
    assert AGENT_FILE.exists(), (
        f"Expected complexity-evaluator agent to exist at {AGENT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created by task dso-1tgy."
    )


def test_complexity_evaluator_agent_frontmatter_name() -> None:
    """YAML frontmatter must contain 'name: complexity-evaluator'."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "name: complexity-evaluator" in frontmatter, (
        "Expected YAML frontmatter of complexity-evaluator.md to contain "
        "'name: complexity-evaluator'. The 'name' field uniquely identifies the agent "
        "and must match the file name convention."
    )


def test_complexity_evaluator_agent_frontmatter_model() -> None:
    """YAML frontmatter must specify 'model: haiku'."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "model: haiku" in frontmatter, (
        "Expected YAML frontmatter of complexity-evaluator.md to contain 'model: haiku'. "
        "The complexity evaluator is a lightweight classification task; haiku is the "
        "appropriate model tier per agent routing conventions."
    )


def test_complexity_evaluator_agent_frontmatter_tools() -> None:
    """YAML frontmatter must list Bash, Read, Glob, and Grep in the tools field."""
    content = _read_agent()
    frontmatter, _ = _parse_frontmatter(content)
    assert "tools:" in frontmatter, (
        "Expected YAML frontmatter of complexity-evaluator.md to contain a 'tools:' field. "
        "Agent definitions must declare the tools the agent is permitted to use."
    )
    for tool in ("Bash", "Read", "Glob", "Grep"):
        assert tool in frontmatter, (
            f"Expected YAML frontmatter 'tools:' field to include '{tool}'. "
            "The complexity evaluator needs Bash (tk show), Read (file content), "
            "Glob (file discovery), and Grep (codebase search) to apply the rubric."
        )


def test_complexity_evaluator_agent_body_five_dimension_rubric() -> None:
    """Markdown body must contain the 5-dimension rubric content."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    assert "Dimension" in body, (
        "Expected complexity-evaluator.md body to contain 'Dimension' headings for the "
        "5-dimension rubric (Files, Layers, Interfaces, scope_certainty, Confidence). "
        "The rubric dimensions are the core evaluation logic."
    )

    for dimension_term in (
        "Files",
        "Layers",
        "Interfaces",
        "scope_certainty",
        "Confidence",
    ):
        assert dimension_term in body, (
            f"Expected complexity-evaluator.md body to reference '{dimension_term}' as one of "
            "the 5 rubric dimensions. All 5 dimensions must be present: Files, Layers, "
            "Interfaces, scope_certainty, and Confidence."
        )


def test_complexity_evaluator_agent_body_tier_schema_mechanism() -> None:
    """Markdown body must describe the tier_schema mechanism for tier vocabulary selection."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)
    assert "tier_schema" in body, (
        "Expected complexity-evaluator.md body to contain 'tier_schema' to document the "
        "tier vocabulary selector mechanism. Callers pass tier_schema=TRIVIAL (outputs "
        "TRIVIAL/MODERATE/COMPLEX) or tier_schema=SIMPLE (outputs SIMPLE/MODERATE/COMPLEX) "
        "as a task argument to select the appropriate tier vocabulary."
    )


def test_complexity_evaluator_agent_body_no_context_routing_table() -> None:
    """Markdown body must NOT contain context-specific routing tables."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    routing_patterns = [
        r"sprint story evaluator",
        r"debug-everything",
        r"de-escalate",
        r"brainstorm.*routing",
    ]
    for pattern in routing_patterns:
        match = re.search(pattern, body, re.IGNORECASE)
        assert match is None, (
            f"Found context-specific routing reference '{match.group(0) if match else pattern}' "
            "in complexity-evaluator.md body. Context-specific routing tables must NOT be "
            "included in the shared agent file — each calling skill's SKILL.md is responsible "
            "for defining its own routing rules based on the agent's output."
        )


def test_complexity_evaluator_agent_body_epic_only_qualitative_overrides() -> None:
    """Markdown body must contain epic-only qualitative override dimensions."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)

    # Must mention epic context
    assert re.search(r"epic", body, re.IGNORECASE), (
        "Expected complexity-evaluator.md body to reference 'epic' in the context of "
        "epic-only qualitative override dimensions. These dimensions apply only when "
        "evaluating epics and must be clearly marked as such."
    )

    # Must contain at least some of the epic-only override dimensions
    epic_override_terms = [
        "multiple personas",
        "foundation",
        "external integration",
    ]
    found_terms = [term for term in epic_override_terms if term in body.lower()]
    assert len(found_terms) >= 2, (
        f"Expected complexity-evaluator.md body to contain at least 2 of the epic-only "
        f"qualitative override dimensions: {epic_override_terms}. "
        f"Found only: {found_terms}. "
        "Epic-only overrides include: multiple personas, UI+backend, new DB migration, "
        "foundation/enhancement candidate, external integration."
    )


def test_complexity_evaluator_agent_body_epic_only_marker() -> None:
    """Epic-only dimensions must be clearly marked as 'Applicable when evaluating epics only'."""
    content = _read_agent()
    _, body = _parse_frontmatter(content)
    assert re.search(
        r"epic.only|evaluating epics only|epics only", body, re.IGNORECASE
    ), (
        "Expected complexity-evaluator.md body to contain an 'epic-only' or "
        "'Applicable when evaluating epics only' marker for the qualitative override "
        "dimensions that apply exclusively to epic-level evaluation. This prevents "
        "the story-level evaluator from incorrectly applying epic-only dimensions."
    )

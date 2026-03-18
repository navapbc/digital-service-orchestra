"""Tests for the task-execution.md prompt template.

Verifies the template contains required sections and placeholders
for sub-agent dispatch.
"""

import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TEMPLATE_PATH = os.path.join(
    REPO_ROOT,
    "plugins",
    "dso",
    "skills",
    "sprint",
    "prompts",
    "task-execution.md",
)


def _read_template() -> str:
    with open(TEMPLATE_PATH) as f:
        return f.read()


class TestTaskExecutionContainsFileOwnershipSection:
    """The template must include file-ownership boundaries for sub-agents."""

    def test_contains_file_ownership_heading(self) -> None:
        content = _read_template()
        assert "### File Ownership Boundaries" in content

    def test_contains_file_ownership_context_placeholder(self) -> None:
        content = _read_template()
        assert "{file_ownership_context}" in content

    def test_contains_other_agents_own_guidance(self) -> None:
        content = _read_template()
        assert "Other agents own" in content

    def test_existing_content_not_disturbed(self) -> None:
        """Existing template content must remain intact."""
        content = _read_template()
        assert "tk show {id}" in content
        assert "### Rules" in content
        assert "### Instructions" in content

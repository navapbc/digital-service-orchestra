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
        assert "ticket show {id}" in content
        assert "### Rules" in content
        assert "### Instructions" in content


class TestTaskExecutionDiscoveredBugType:
    """Sub-agents must use '-t bug' when creating tickets for discovered bugs.

    CLAUDE.md rule 'Always Do #9' instructs sub-agents to search for the same
    anti-pattern elsewhere and create tracking tickets. Those tickets must use
    type 'bug', not the default 'task'. The template's discovered-work example
    must use '-t bug' so sub-agents follow the correct convention.
    """

    def test_discovered_work_uses_bug_type_not_task(self) -> None:
        """The tk create example in the Discovered work section must use '-t bug'.

        The old template used '-t task' for all discovered work, causing orphan
        bug tickets to be misclassified. Sub-agents must use '-t bug' when
        creating tickets for discovered defects or anti-patterns.
        """
        content = _read_template()
        assert "-t bug" in content or "--type bug" in content, (
            "task-execution.md must instruct sub-agents to use '-t bug' when "
            "creating tickets for discovered bugs. Found no '-t bug' or "
            "'--type bug' in the template. The 'Discovered work' section "
            "currently uses '-t task', which misclassifies bug tickets."
        )

    def test_discovered_work_does_not_use_task_type_for_bugs(self) -> None:
        """The tk create example for discovered bugs must not use '-t task'.

        Using '-t task' as the type for bug ticket creation causes orphan bug
        tickets to appear as tasks, making triage harder.
        """
        import re

        content = _read_template()
        # The tk create line in the Discovered work section (step 8) must not
        # instruct sub-agents to use '-t task' when creating tracking tickets
        # for discovered defects.
        # Match lines that actually invoke tk create with -t task as the type
        # argument (not lines that merely mention '-t task' in a comment).
        # The pattern looks for: tk create followed (possibly with other args)
        # by -t task where 'task' is a positional value (not part of a longer word).
        bad_pattern = re.compile(r"tk create\b.*?\B-t task\b")
        lines = content.splitlines()
        for i, line in enumerate(lines):
            if bad_pattern.search(line):
                context = "\n".join(lines[max(0, i - 3) : i + 3])
                assert False, (
                    f"task-execution.md line {i + 1} uses 'tk create ... -t task' "
                    "which causes discovered bug tickets to be misclassified as tasks. "
                    f"Context:\n{context}"
                )

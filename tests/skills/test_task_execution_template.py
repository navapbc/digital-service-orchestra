"""Tests for the task-execution.md prompt template.

Verifies the template contains required sections and placeholders
for sub-agent dispatch.
"""

import os
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Add tests/lib to sys.path for shared helpers
_TESTS_LIB = os.path.join(REPO_ROOT, "tests", "lib")
if _TESTS_LIB not in sys.path:
    sys.path.insert(0, _TESTS_LIB)

from markdown_helpers import extract_section as _extract_section_from_template  # noqa: E402

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
        """The ticket create example in the Discovered work section must use '-t bug'.

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
        """The ticket create example for discovered bugs must not use '-t task'.

        Using '-t task' as the type for bug ticket creation causes orphan bug
        tickets to appear as tasks, making triage harder.
        """
        import re

        content = _read_template()
        # The ticket create line in the Discovered work section (step 8) must not
        # instruct sub-agents to use '-t task' when creating tracking tickets
        # for discovered defects.
        # Match lines that actually invoke ticket create with -t task as the type
        # argument (not lines that merely mention '-t task' in a comment).
        # The pattern looks for: ticket create followed (possibly with other args)
        # by -t task where 'task' is a positional value (not part of a longer word).
        bad_pattern = re.compile(r"ticket create\b.*?\B-t task\b")
        lines = content.splitlines()
        for i, line in enumerate(lines):
            if bad_pattern.search(line):
                context = "\n".join(lines[max(0, i - 3) : i + 3])
                assert False, (
                    f"task-execution.md line {i + 1} uses 'ticket create ... -t task' "
                    "which causes discovered bug tickets to be misclassified as tasks. "
                    f"Context:\n{context}"
                )


class TestTaskExecutionProhibitedFixPatterns:
    """task-execution.md must contain a Prohibited Fix Patterns section.

    TDD spec for task 2eae-abec (RED task):
    The template dispatched to sub-agents must include a section documenting
    5 anti-patterns that sub-agents must never use to make tests pass by hiding
    failures rather than fixing root causes:
      1. Skipping or removing failing tests
      2. Loosening assertions to make tests pass
      3. Adding broad exception handlers to swallow errors
      4. Downgrading error severity (e.g., assert → warning)
      5. Commenting out failing code
    """

    def _get_section(self) -> str:
        """Return the Prohibited Fix Patterns section content from the template."""
        content = _read_template()
        for prefix in ("## Prohibited Fix Patterns", "### Prohibited Fix Patterns"):
            section = _extract_section_from_template(content, prefix)
            if section:
                return section
        return ""

    def test_prohibited_fix_patterns_section_exists(self) -> None:
        """The template must contain a 'Prohibited Fix Patterns' section heading."""
        content = _read_template()
        assert (
            "## Prohibited Fix Patterns" in content
            or "### Prohibited Fix Patterns" in content
        ), (
            "Expected task-execution.md to contain a 'Prohibited Fix Patterns' section "
            "heading (## or ###). This section documents anti-patterns that sub-agents "
            "must never use to make tests pass by hiding failures rather than fixing "
            "root causes."
        )

    def test_anti_pattern_1_skip_tests_present(self) -> None:
        """The section must document the 'skipping/removing tests' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert (
            "pytest.mark.skip" in section
            or "@skip" in section
            or "skip" in section.lower()
        ), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to document "
            "the 'skipping or removing tests' anti-pattern."
        )
        assert "```" in section, (
            "Expected 'Prohibited Fix Patterns' section to use fenced code blocks (```) "
            "for anti-pattern code examples."
        )

    def test_anti_pattern_2_loosen_assertions_present(self) -> None:
        """The section must document the 'loosening assertions' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert "loosen" in section.lower() or "assertion" in section.lower(), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to document "
            "the 'loosening assertions' anti-pattern."
        )

    def test_anti_pattern_3_broad_exception_present(self) -> None:
        """The section must document the 'broad exception handlers' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert "except" in section or "exception" in section.lower(), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to document "
            "the 'broad exception handlers' anti-pattern."
        )

    def test_anti_pattern_4_downgrade_severity_present(self) -> None:
        """The section must document the 'downgrading error severity' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert (
            "warning" in section.lower()
            or "severity" in section.lower()
            or "downgrade" in section.lower()
        ), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to document "
            "the 'downgrading error severity' anti-pattern."
        )

    def test_anti_pattern_5_comment_out_present(self) -> None:
        """The section must document the 'commenting out failing code' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert (
            "comment" in section.lower()
            or "# assert" in section
            or "# check" in section
        ), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to document "
            "the 'commenting out failing code' anti-pattern."
        )

    def test_do_this_instead_alternatives_present(self) -> None:
        """The section must include 'Do this instead' alternatives for anti-patterns."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to provide "
            "'Do this instead' alternatives so sub-agents know the correct approach."
        )

    def test_rationale_present(self) -> None:
        """The section must include rationale explaining why these patterns are prohibited."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert any(
            phrase in section.lower()
            for phrase in [
                "root cause",
                "hides",
                "masks",
                "cover",
                "real failure",
                "genuine",
            ]
        ), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to include "
            "rationale for why each anti-pattern is prohibited (e.g., 'hides the root cause')."
        )

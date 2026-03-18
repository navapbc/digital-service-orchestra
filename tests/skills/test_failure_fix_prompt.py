"""Tests that test-failure-fix.md contains file ownership boundaries section."""

import subprocess
from pathlib import Path

REPO_ROOT = Path(
    subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
)
TEMPLATE_PATH = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "debug-everything"
    / "prompts"
    / "test-failure-fix.md"
)


class TestFailureFixContainsFileOwnershipSection:
    """Verify test-failure-fix.md contains file ownership boundaries."""

    def test_failure_fix_contains_file_ownership_section(self):
        """The template must contain a File Ownership Boundaries heading."""
        content = TEMPLATE_PATH.read_text()
        assert "### File Ownership Boundaries" in content

    def test_failure_fix_contains_file_ownership_placeholder(self):
        """The template must contain the {file_ownership_context} placeholder."""
        content = TEMPLATE_PATH.read_text()
        assert "{file_ownership_context}" in content

    def test_anti_patterns_section_preserved(self):
        """The existing Anti-Patterns section must not be disturbed."""
        content = TEMPLATE_PATH.read_text()
        assert "### Anti-Patterns" in content

    def test_file_ownership_before_anti_patterns(self):
        """File Ownership Boundaries must appear before Anti-Patterns."""
        content = TEMPLATE_PATH.read_text()
        ownership_pos = content.index("### File Ownership Boundaries")
        anti_patterns_pos = content.index("### Anti-Patterns")
        assert ownership_pos < anti_patterns_pos

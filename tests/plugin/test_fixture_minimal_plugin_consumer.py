"""Tests for the minimal-plugin-consumer fixture used in the claude-safe portability smoke test.

Verifies that the fixture at:
  lockpick-workflow/tests/fixtures/minimal-plugin-consumer/workflow-config.yaml

exists and contains only 'version: "1.0.0"' as its substantive content —
no project-specific keys like database, infrastructure, worktree, or session sections.
"""

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_CONFIG_PATH = (
    REPO_ROOT
    / "tests"
    / "fixtures"
    / "minimal-plugin-consumer"
    / "workflow-config.yaml"
)


class TestFixtureConfigContainsOnlyVersion:
    """The minimal-plugin-consumer fixture contains only a version key."""

    def test_fixture_file_exists(self):
        """Fixture workflow-config.yaml exists at the expected path."""
        assert FIXTURE_CONFIG_PATH.exists(), (
            f"Fixture file not found at {FIXTURE_CONFIG_PATH}. "
            "Create lockpick-workflow/tests/fixtures/minimal-plugin-consumer/workflow-config.yaml"
        )

    def test_fixture_config_contains_only_version(self):
        """Fixture workflow-config.yaml has only 'version: \"1.0.0\"' as substantive content.

        All non-comment, non-empty lines must consist solely of the version key.
        No project-specific sections (database, infrastructure, worktree, session) are present.
        """
        assert FIXTURE_CONFIG_PATH.exists(), f"Fixture file not found at {FIXTURE_CONFIG_PATH}"

        content = FIXTURE_CONFIG_PATH.read_text()
        lines = content.splitlines()

        # Collect substantive lines (non-comment, non-empty)
        substantive_lines = [
            line for line in lines if line.strip() and not line.strip().startswith("#")
        ]

        assert (
            len(substantive_lines) == 1
        ), f"Expected exactly 1 substantive line, got {len(substantive_lines)}: {substantive_lines}"
        assert (
            substantive_lines[0].strip() == 'version: "1.0.0"'
        ), f"Expected 'version: \"1.0.0\"', got '{substantive_lines[0].strip()}'"

    def test_fixture_config_has_no_project_specific_keys(self):
        """Fixture workflow-config.yaml contains no project-specific section keys."""
        assert FIXTURE_CONFIG_PATH.exists(), f"Fixture file not found at {FIXTURE_CONFIG_PATH}"

        content = FIXTURE_CONFIG_PATH.read_text()
        forbidden_pattern = re.compile(
            r"^(database|infrastructure|worktree|session):", re.MULTILINE
        )
        match = forbidden_pattern.search(content)
        assert match is None, (
            f"Fixture contains forbidden project-specific key '{match.group()}' — "
            "the minimal-plugin-consumer fixture must contain only 'version: \"1.0.0\"'"
        )

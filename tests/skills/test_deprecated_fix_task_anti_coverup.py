"""Tests for anti-cover-up patterns in deprecated fix-task prompt templates.

TDD spec for task 7fef-a8fb (RED task):
- plugins/dso/skills/debug-everything/prompts/fix-task-tdd.md must contain an
  Anti-Cover-Up (or equivalent) section with 5 specific anti-patterns documented,
  each including:
    1. Pattern name
    2. 'Do this instead' alternative

- plugins/dso/skills/debug-everything/prompts/fix-task-mechanical.md must contain
  the same 5 anti-patterns.

Anti-patterns required:
  1. Skipping or removing failing tests
  2. Loosening assertions to make tests pass
  3. Adding broad exception handlers to swallow errors
  4. Downgrading error severity (e.g., assert → warning)
  5. Commenting out failing code

All tests in this file must FAIL (RED) before the template updates in the next task.
Run: python -m pytest tests/skills/test_deprecated_fix_task_anti_coverup.py -v
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX_TASK_TDD = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "debug-everything"
    / "prompts"
    / "fix-task-tdd.md"
)
FIX_TASK_MECHANICAL = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "debug-everything"
    / "prompts"
    / "fix-task-mechanical.md"
)


def _extract_anti_coverup_section(content: str) -> str:
    """Extract the Anti-Cover-Up (or Anti-Patterns) section from the template content.

    Looks for a section heading containing 'Anti-Cover-Up', 'anti-cover-up',
    'cover-up', or 'cover up'. Returns section content up to the next heading.
    """
    lines = content.splitlines()
    in_section = False
    section_lines = []
    heading_level = ""

    for line in lines:
        stripped = line.strip()
        # Detect section heading
        if not in_section:
            lower = stripped.lower()
            if "anti-cover" in lower or "cover-up" in lower or "coverup" in lower:
                # Determine heading level (##, ###, etc.)
                for prefix in ("####", "###", "##", "#"):
                    if stripped.startswith(prefix + " "):
                        heading_level = prefix
                        break
                in_section = True
                section_lines.append(line)
                continue
        else:
            # Stop at a heading of the same or higher level
            if heading_level and line.startswith(heading_level + " ") and section_lines:
                break
            section_lines.append(line)

    return "\n".join(section_lines)


class TestFixTaskTddAntiCoverup:
    """fix-task-tdd.md must contain an Anti-Cover-Up section with 5 specific patterns."""

    def _read(self) -> str:
        return FIX_TASK_TDD.read_text()

    def _get_section(self) -> str:
        return _extract_anti_coverup_section(self._read())

    def test_anti_coverup_section_exists(self) -> None:
        """fix-task-tdd.md must contain an 'Anti-Cover-Up' section heading."""
        section = self._get_section()
        assert section, (
            "Expected fix-task-tdd.md to contain an 'Anti-Cover-Up' section "
            "(heading containing 'anti-cover-up', 'cover-up', or similar). "
            "This section documents the 5 patterns that agents must never use "
            "to hide failures rather than fixing root causes. "
            "RED test — section not yet present."
        )

    def test_anti_pattern_1_skip_tests_present(self) -> None:
        """The Anti-Cover-Up section must name the 'skipping/removing tests' pattern."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-tdd.md"
        assert "skip" in section.lower() or "remov" in section.lower(), (
            "Expected Anti-Cover-Up section in fix-task-tdd.md to name the "
            "'skipping or removing tests' anti-pattern. "
            "RED test — pattern not yet documented."
        )

    def test_anti_pattern_1_skip_tests_do_this_instead(self) -> None:
        """The skip-tests anti-pattern in fix-task-tdd.md must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-tdd.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected Anti-Cover-Up section in fix-task-tdd.md to provide a "
            "'Do this instead' alternative for the skip-tests anti-pattern. "
            "RED test — alternative not yet present."
        )

    def test_anti_pattern_2_loosen_assertions_present(self) -> None:
        """The Anti-Cover-Up section must name the 'loosening assertions' pattern."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-tdd.md"
        assert "loosen" in section.lower() or "assertion" in section.lower(), (
            "Expected Anti-Cover-Up section in fix-task-tdd.md to name the "
            "'loosening assertions' anti-pattern. "
            "RED test — pattern not yet documented."
        )

    def test_anti_pattern_2_loosen_assertions_do_this_instead(self) -> None:
        """The loosen-assertions anti-pattern in fix-task-tdd.md must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-tdd.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected Anti-Cover-Up section in fix-task-tdd.md to provide a "
            "'Do this instead' alternative for the loosen-assertions anti-pattern. "
            "RED test — alternative not yet present."
        )

    def test_anti_pattern_3_broad_exception_present(self) -> None:
        """The Anti-Cover-Up section must name the 'broad exception handlers' pattern."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-tdd.md"
        assert "except" in section.lower() or "exception" in section.lower(), (
            "Expected Anti-Cover-Up section in fix-task-tdd.md to name the "
            "'broad exception handlers' anti-pattern. "
            "RED test — pattern not yet documented."
        )

    def test_anti_pattern_3_broad_exception_do_this_instead(self) -> None:
        """The broad-exception anti-pattern in fix-task-tdd.md must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-tdd.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected Anti-Cover-Up section in fix-task-tdd.md to provide a "
            "'Do this instead' alternative for the broad-exception anti-pattern. "
            "RED test — alternative not yet present."
        )

    def test_anti_pattern_4_downgrade_severity_present(self) -> None:
        """The Anti-Cover-Up section must name the 'downgrading error severity' pattern."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-tdd.md"
        assert (
            "downgrad" in section.lower()
            or "severity" in section.lower()
            or "warning" in section.lower()
        ), (
            "Expected Anti-Cover-Up section in fix-task-tdd.md to name the "
            "'downgrading error severity' anti-pattern. "
            "RED test — pattern not yet documented."
        )

    def test_anti_pattern_4_downgrade_severity_do_this_instead(self) -> None:
        """The downgrade-severity anti-pattern in fix-task-tdd.md must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-tdd.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected Anti-Cover-Up section in fix-task-tdd.md to provide a "
            "'Do this instead' alternative for the downgrade-severity anti-pattern. "
            "RED test — alternative not yet present."
        )

    def test_anti_pattern_5_comment_out_present(self) -> None:
        """The Anti-Cover-Up section must name the 'commenting out failing code' pattern."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-tdd.md"
        assert "comment" in section.lower(), (
            "Expected Anti-Cover-Up section in fix-task-tdd.md to name the "
            "'commenting out failing code' anti-pattern. "
            "RED test — pattern not yet documented."
        )

    def test_anti_pattern_5_comment_out_do_this_instead(self) -> None:
        """The comment-out anti-pattern in fix-task-tdd.md must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-tdd.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected Anti-Cover-Up section in fix-task-tdd.md to provide a "
            "'Do this instead' alternative for the comment-out anti-pattern. "
            "RED test — alternative not yet present."
        )


class TestFixTaskMechanicalAntiCoverup:
    """fix-task-mechanical.md must contain an Anti-Cover-Up section with 5 specific patterns."""

    def _read(self) -> str:
        return FIX_TASK_MECHANICAL.read_text()

    def _get_section(self) -> str:
        return _extract_anti_coverup_section(self._read())

    def test_anti_coverup_section_exists(self) -> None:
        """fix-task-mechanical.md must contain an 'Anti-Cover-Up' section heading."""
        section = self._get_section()
        assert section, (
            "Expected fix-task-mechanical.md to contain an 'Anti-Cover-Up' section "
            "(heading containing 'anti-cover-up', 'cover-up', or similar). "
            "This section documents the 5 patterns that agents must never use "
            "to hide failures rather than fixing root causes. "
            "RED test — section not yet present."
        )

    def test_anti_pattern_1_skip_tests_present(self) -> None:
        """The Anti-Cover-Up section must name the 'skipping/removing tests' pattern."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-mechanical.md"
        assert "skip" in section.lower() or "remov" in section.lower(), (
            "Expected Anti-Cover-Up section in fix-task-mechanical.md to name the "
            "'skipping or removing tests' anti-pattern. "
            "RED test — pattern not yet documented."
        )

    def test_anti_pattern_1_skip_tests_do_this_instead(self) -> None:
        """The skip-tests anti-pattern in fix-task-mechanical.md must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-mechanical.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected Anti-Cover-Up section in fix-task-mechanical.md to provide a "
            "'Do this instead' alternative for the skip-tests anti-pattern. "
            "RED test — alternative not yet present."
        )

    def test_anti_pattern_2_loosen_assertions_present(self) -> None:
        """The Anti-Cover-Up section must name the 'loosening assertions' pattern."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-mechanical.md"
        assert "loosen" in section.lower() or "assertion" in section.lower(), (
            "Expected Anti-Cover-Up section in fix-task-mechanical.md to name the "
            "'loosening assertions' anti-pattern. "
            "RED test — pattern not yet documented."
        )

    def test_anti_pattern_2_loosen_assertions_do_this_instead(self) -> None:
        """The loosen-assertions anti-pattern in fix-task-mechanical.md must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-mechanical.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected Anti-Cover-Up section in fix-task-mechanical.md to provide a "
            "'Do this instead' alternative for the loosen-assertions anti-pattern. "
            "RED test — alternative not yet present."
        )

    def test_anti_pattern_3_broad_exception_present(self) -> None:
        """The Anti-Cover-Up section must name the 'broad exception handlers' pattern."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-mechanical.md"
        assert "except" in section.lower() or "exception" in section.lower(), (
            "Expected Anti-Cover-Up section in fix-task-mechanical.md to name the "
            "'broad exception handlers' anti-pattern. "
            "RED test — pattern not yet documented."
        )

    def test_anti_pattern_3_broad_exception_do_this_instead(self) -> None:
        """The broad-exception anti-pattern in fix-task-mechanical.md must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-mechanical.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected Anti-Cover-Up section in fix-task-mechanical.md to provide a "
            "'Do this instead' alternative for the broad-exception anti-pattern. "
            "RED test — alternative not yet present."
        )

    def test_anti_pattern_4_downgrade_severity_present(self) -> None:
        """The Anti-Cover-Up section must name the 'downgrading error severity' pattern."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-mechanical.md"
        assert (
            "downgrad" in section.lower()
            or "severity" in section.lower()
            or "warning" in section.lower()
        ), (
            "Expected Anti-Cover-Up section in fix-task-mechanical.md to name the "
            "'downgrading error severity' anti-pattern. "
            "RED test — pattern not yet documented."
        )

    def test_anti_pattern_4_downgrade_severity_do_this_instead(self) -> None:
        """The downgrade-severity anti-pattern in fix-task-mechanical.md must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-mechanical.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected Anti-Cover-Up section in fix-task-mechanical.md to provide a "
            "'Do this instead' alternative for the downgrade-severity anti-pattern. "
            "RED test — alternative not yet present."
        )

    def test_anti_pattern_5_comment_out_present(self) -> None:
        """The Anti-Cover-Up section must name the 'commenting out failing code' pattern."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-mechanical.md"
        assert "comment" in section.lower(), (
            "Expected Anti-Cover-Up section in fix-task-mechanical.md to name the "
            "'commenting out failing code' anti-pattern. "
            "RED test — pattern not yet documented."
        )

    def test_anti_pattern_5_comment_out_do_this_instead(self) -> None:
        """The comment-out anti-pattern in fix-task-mechanical.md must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Anti-Cover-Up section not found in fix-task-mechanical.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected Anti-Cover-Up section in fix-task-mechanical.md to provide a "
            "'Do this instead' alternative for the comment-out anti-pattern. "
            "RED test — alternative not yet present."
        )

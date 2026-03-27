"""Tests for the anti-cover-up (Prohibited Fix Patterns) section in SUB-AGENT-BOUNDARIES.md.

TDD spec for task 2eae-abec (RED task):
- plugins/dso/docs/SUB-AGENT-BOUNDARIES.md must contain a 'Prohibited Fix Patterns' section
  with 5 specific anti-patterns documented, each including:
    1. Pattern name
    2. Code example
    3. Rationale
    4. 'Do this instead' alternative

Anti-patterns required:
  1. Skipping or removing failing tests
  2. Loosening assertions to make tests pass
  3. Adding broad exception handlers to swallow errors
  4. Downgrading error severity (e.g., assert → warning)
  5. Commenting out failing code
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DOC_FILE = REPO_ROOT / "plugins" / "dso" / "docs" / "SUB-AGENT-BOUNDARIES.md"


def _read_doc() -> str:
    return DOC_FILE.read_text()


def _extract_section(content: str, section_heading: str) -> str:
    """Extract content from a section heading until the next same-level heading."""
    lines = content.splitlines()
    in_section = False
    section_lines = []
    heading_prefix = section_heading.split(" ")[0]  # e.g., "##" or "###"

    for line in lines:
        if line.strip() == section_heading or line.startswith(section_heading + " "):
            in_section = True
            section_lines.append(line)
            continue
        if in_section:
            # Stop at a heading of the same or higher level
            if line.startswith(heading_prefix + " ") and line != section_heading:
                break
            section_lines.append(line)

    return "\n".join(section_lines)


class TestSubAgentBoundariesAntiCoverup:
    """SUB-AGENT-BOUNDARIES.md must contain a Prohibited Fix Patterns section."""

    def test_prohibited_fix_patterns_section_exists(self) -> None:
        """The document must contain a 'Prohibited Fix Patterns' section heading."""
        content = _read_doc()
        assert (
            "## Prohibited Fix Patterns" in content
            or "### Prohibited Fix Patterns" in content
        ), (
            "Expected SUB-AGENT-BOUNDARIES.md to contain a 'Prohibited Fix Patterns' "
            "section heading (## or ###). This section documents anti-patterns that "
            "sub-agents must never use to make tests pass by hiding failures rather "
            "than fixing root causes."
        )

    def _get_section(self) -> str:
        """Return the Prohibited Fix Patterns section content."""
        content = _read_doc()
        for prefix in ("## Prohibited Fix Patterns", "### Prohibited Fix Patterns"):
            section = _extract_section(content, prefix)
            if section:
                return section
        return ""

    def test_anti_pattern_1_skip_tests_name_present(self) -> None:
        """The section must name the 'skipping/removing tests' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert "skip" in section.lower() or "remove" in section.lower(), (
            "Expected 'Prohibited Fix Patterns' section to name the "
            "'skipping or removing tests' anti-pattern."
        )

    def test_anti_pattern_1_skip_tests_code_example_present(self) -> None:
        """The skip-tests anti-pattern must include a code example within the section."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert "pytest.mark.skip" in section or "@skip" in section, (
            "Expected 'Prohibited Fix Patterns' section to include a code example "
            "showing 'pytest.mark.skip' or similar test-skipping pattern."
        )
        assert "```" in section, (
            "Expected 'Prohibited Fix Patterns' section to use fenced code blocks (```) "
            "for anti-pattern code examples."
        )

    def test_anti_pattern_1_skip_tests_rationale_present(self) -> None:
        """The skip-tests anti-pattern must include a rationale in the section."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
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
            "Expected 'Prohibited Fix Patterns' section to include a rationale for why "
            "skipping tests is prohibited (e.g., 'hides the root cause')."
        )

    def test_anti_pattern_1_skip_tests_do_this_instead_present(self) -> None:
        """The skip-tests anti-pattern must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected 'Prohibited Fix Patterns' section to provide a 'Do this instead' "
            "alternative for the skip-tests anti-pattern."
        )

    def test_anti_pattern_2_loosen_assertions_name_present(self) -> None:
        """The section must name the 'loosening assertions' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert "loosen" in section.lower() or "assertion" in section.lower(), (
            "Expected 'Prohibited Fix Patterns' section to name the "
            "'loosening assertions' anti-pattern."
        )

    def test_anti_pattern_2_loosen_assertions_code_example_present(self) -> None:
        """The loosening-assertions anti-pattern must include a code example."""
        ap2_section = _extract_section(_read_doc(), "### 2. Loosening assertions")
        assert ap2_section, (
            "Anti-pattern #2 'Loosening assertions' sub-section not found"
        )
        assert "assert" in ap2_section and "```" in ap2_section, (
            "Expected anti-pattern #2 'Loosening assertions' sub-section to include a "
            "code example showing the loosening-assertions anti-pattern (e.g., changing "
            "assertEqual to assertIn or assertTrue)."
        )

    def test_anti_pattern_2_loosen_assertions_do_this_instead_present(self) -> None:
        """The loosening-assertions anti-pattern must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected 'Prohibited Fix Patterns' section to provide a 'Do this instead' "
            "alternative for the loosening-assertions anti-pattern."
        )

    def test_anti_pattern_3_broad_exception_name_present(self) -> None:
        """The section must name the 'broad exception handlers' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert "except" in section or "exception" in section.lower(), (
            "Expected 'Prohibited Fix Patterns' section to name the "
            "'broad exception handlers' anti-pattern."
        )

    def test_anti_pattern_3_broad_exception_code_example_present(self) -> None:
        """The broad-exception-handler anti-pattern must include a code example."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert (
            "except Exception" in section or "except:" in section
        ) and "```" in section, (
            "Expected 'Prohibited Fix Patterns' section to include a code example "
            "showing 'except Exception: pass' or a bare 'except:' block."
        )

    def test_anti_pattern_3_broad_exception_do_this_instead_present(self) -> None:
        """The broad-exception anti-pattern must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected 'Prohibited Fix Patterns' section to provide a 'Do this instead' "
            "alternative for the broad-exception-handler anti-pattern."
        )

    def test_anti_pattern_4_downgrade_severity_name_present(self) -> None:
        """The section must name the 'downgrading error severity' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert (
            "warning" in section.lower()
            or "severity" in section.lower()
            or "downgrade" in section.lower()
        ), (
            "Expected 'Prohibited Fix Patterns' section to name the "
            "'downgrading error severity' anti-pattern."
        )

    def test_anti_pattern_4_downgrade_severity_code_example_present(self) -> None:
        """The downgrade-severity anti-pattern must include a code example."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert (
            "log.warning" in section
            or "logging.warning" in section
            or "WARNING" in section
        ) and "```" in section, (
            "Expected 'Prohibited Fix Patterns' section to include a code example "
            "showing downgrading error severity (e.g., assert → logging.warning)."
        )

    def test_anti_pattern_4_downgrade_severity_do_this_instead_present(self) -> None:
        """The downgrade-severity anti-pattern must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected 'Prohibited Fix Patterns' section to provide a 'Do this instead' "
            "alternative for the downgrade-severity anti-pattern."
        )

    def test_anti_pattern_5_comment_out_name_present(self) -> None:
        """The section must name the 'commenting out failing code' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert "comment" in section.lower(), (
            "Expected 'Prohibited Fix Patterns' section to name the "
            "'commenting out failing code' anti-pattern."
        )

    def test_anti_pattern_5_comment_out_code_example_present(self) -> None:
        """The comment-out-code anti-pattern must include a code example."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        # A code block with a commented-out assertion
        assert (
            "# assert" in section or "# validate" in section or "# check" in section
        ) and "```" in section, (
            "Expected 'Prohibited Fix Patterns' section to include a code example "
            "showing commented-out assertions or failing code (e.g., '# assert result == expected')."
        )

    def test_anti_pattern_5_comment_out_do_this_instead_present(self) -> None:
        """The comment-out anti-pattern must include a 'Do this instead' alternative."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected 'Prohibited Fix Patterns' section to provide a 'Do this instead' "
            "alternative for the comment-out anti-pattern."
        )

    def test_anti_pattern_2_code_example_scoped_to_subsection(self) -> None:
        """Anti-pattern #2 code example check must target its own sub-section.

        Regression test for bug 7e2c-3b25: the original assertion used _get_section()
        (the full 'Prohibited Fix Patterns' section), so it would pass even if AP2 had
        no code example — content from other anti-patterns satisfied the check.
        This test verifies AP2's sub-section independently contains both elements.
        """
        ap2_section = _extract_section(_read_doc(), "### 2. Loosening assertions")
        assert ap2_section, (
            "Anti-pattern #2 'Loosening assertions' sub-section not found"
        )
        assert "assert" in ap2_section, (
            "Anti-pattern #2 sub-section must reference 'assert' in its code example"
        )
        assert "```" in ap2_section, (
            "Anti-pattern #2 sub-section must contain a code block"
        )

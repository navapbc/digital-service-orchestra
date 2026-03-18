"""Tests for new categories in ACCEPTANCE-CRITERIA-LIBRARY.md.

These are GREEN-phase tests. They assert the presence of two new
categories added by task dso-gp00.
"""

import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
AC_LIBRARY_PATH = os.path.join(
    REPO_ROOT,
    "plugins",
    "dso",
    "docs",
    "ACCEPTANCE-CRITERIA-LIBRARY.md",
)


def _read_ac_library() -> str:
    with open(AC_LIBRARY_PATH) as f:
        return f.read()


def test_red_test_task_category_present() -> None:
    """'Category: RED Test Task' must be present in ACCEPTANCE-CRITERIA-LIBRARY.md."""
    content = _read_ac_library()
    assert "Category: RED Test Task" in content, (
        f"'Category: RED Test Task' not found in {AC_LIBRARY_PATH}. "
        "Add the RED Test Task category section to the library."
    )


def test_test_exempt_task_category_present() -> None:
    """'Category: Test-Exempt Task' must be present in ACCEPTANCE-CRITERIA-LIBRARY.md."""
    content = _read_ac_library()
    assert "Category: Test-Exempt Task" in content, (
        f"'Category: Test-Exempt Task' not found in {AC_LIBRARY_PATH}. "
        "Add the Test-Exempt Task category section to the library."
    )


def test_test_exempt_justification_criterion_present() -> None:
    """The test-exempt category must include a justification criterion."""
    content = _read_ac_library()
    assert "Category: Test-Exempt Task" in content, (
        f"'Category: Test-Exempt Task' not found in {AC_LIBRARY_PATH}."
    )
    idx = content.index("Category: Test-Exempt Task")
    section = content[idx : idx + 500]
    assert "justification" in section.lower(), (
        "The 'Category: Test-Exempt Task' section must contain a justification criterion "
        f"within 500 characters of the category header. Found section:\n{section}"
    )
